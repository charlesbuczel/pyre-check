(* Copyright (c) 2016-present, Facebook, Inc.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree. *)

open Core
module Path = Pyre.Path

exception ConnectionError of string

exception SubscriptionError of string

module Raw = struct
  module Response = struct
    type t =
      | Ok of Yojson.Safe.t
      | EndOfStream
      | Error of string
  end

  module Connection = struct
    type t = {
      send: Yojson.Safe.t -> unit Lwt.t;
      receive: unit -> Response.t Lwt.t;
      shutdown: unit -> unit Lwt.t;
    }

    let send { send; _ } = send

    let receive { receive; _ } = receive

    let shutdown { shutdown; _ } = shutdown
  end

  type t = { open_connection: unit -> Connection.t Lwt.t }

  let open_connection { open_connection } = open_connection ()

  let shutdown_connection connection = Connection.shutdown connection ()

  let with_connection ~f { open_connection } =
    let open Lwt.Infix in
    open_connection ()
    >>= fun connection -> Lwt.finalize (fun () -> f connection) (Connection.shutdown connection)


  let create_for_testing ~send ~receive () =
    let receive () =
      let open Lwt.Infix in
      receive ()
      >>= function
      | Some json -> Lwt.return (Response.Ok json)
      | None -> Lwt.return Response.EndOfStream
    in
    let shutdown () = Lwt.return_unit in
    let mock_connection = { Connection.send; receive; shutdown } in
    { open_connection = (fun () -> Lwt.return mock_connection) }


  let get_watchman_socket_name () =
    let open Lwt.Infix in
    LwtSubprocess.run "watchman" ~arguments:["--no-pretty"; "get-sockname"]
    >>= fun { LwtSubprocess.Completed.status; stdout; stderr } ->
    match status with
    | Caml.Unix.WEXITED 0 ->
        let socket_name =
          try
            Yojson.Safe.from_string stdout
            |> Yojson.Safe.Util.member "sockname"
            |> Yojson.Safe.Util.to_string
          with
          | Yojson.Json_error message ->
              let message =
                Format.sprintf "Cannot parse JSON result from watchman getsockname: %s" message
              in
              raise (ConnectionError message)
        in
        Lwt.return socket_name
    | WEXITED 127 ->
        let message =
          Format.sprintf
            "Cannot find watchman exectuable under PATH: %s"
            (Option.value (Sys_utils.getenv_path ()) ~default:"(not set)")
        in
        raise (ConnectionError message)
    | WEXITED code ->
        let message = Format.sprintf "Watchman exited code %d, stderr = %S" code stderr in
        raise (ConnectionError message)
    | WSIGNALED signal ->
        let message =
          Format.sprintf "watchman signaled with %s signal" (PrintSignal.string_of_signal signal)
        in
        raise (ConnectionError message)
    | WSTOPPED signal ->
        let message =
          Format.sprintf "watchman stopped with %s signal" (PrintSignal.string_of_signal signal)
        in
        raise (ConnectionError message)


  let create_exn () =
    let open Lwt.Infix in
    Log.info "Initializing file watching service...";
    get_watchman_socket_name ()
    >>= fun socket_name ->
    let open_connection () =
      Log.info "Connecting to watchman...";
      Lwt_io.open_connection (Lwt_unix.ADDR_UNIX socket_name)
      >>= fun (input_channel, output_channel) ->
      Log.info "Established watchman connection.";
      let send json = Yojson.Safe.to_string json |> Lwt_io.write_line output_channel in
      let receive () =
        Lwt_io.read_line_opt input_channel
        >>= function
        | None -> Lwt.return Response.EndOfStream
        | Some line -> (
            try
              let json = Yojson.Safe.from_string line in
              Lwt.return (Response.Ok json)
            with
            | Yojson.Json_error message ->
                let message =
                  Format.sprintf "Cannot parse JSON from watchman response: %s" message
                in
                Lwt.return (Response.Error message) )
      in
      let shutdown () =
        Log.info "Shutting down watchman connection...";
        Lwt_io.close input_channel >>= fun () -> Lwt_io.close output_channel
      in
      Lwt.return { Connection.send; receive; shutdown }
    in
    Lwt.return { open_connection }


  let create () =
    let open Lwt.Infix in
    Lwt.catch
      (fun () -> create_exn () >>= fun raw -> Lwt.return (Result.Ok raw))
      (fun exn ->
        let message =
          Format.sprintf "Cannot initialize watchman due to exception: %s" (Exn.to_string exn)
        in
        Lwt.return (Result.Error message))
end

module Subscriber = struct
  module Setting = struct
    type t = {
      raw: Raw.t;
      (* Watchman requires its root to be an absolute path. *)
      root: Path.t;
      (* The subscriber will track changes in files that satisfies any of the following condition:
       * - Suffix of the file is included in `suffixes`.
       * - File name of the file is included in `base_names`.
       *)
      base_names: string list;
      suffixes: string list;
    }
  end

  type t = {
    connection: Raw.Connection.t;
    initial_clock: string;
  }

  let subscribe { Setting.raw; root; base_names; suffixes } =
    let open Lwt.Infix in
    Raw.open_connection raw
    >>= fun connection ->
    let do_subscribe () =
      let request =
        let base_names =
          List.map base_names ~f:(fun base_name -> `List [`String "match"; `String base_name])
        in
        let suffixes =
          List.map suffixes ~f:(fun suffix -> `List [`String "suffix"; `String suffix])
        in
        `List
          [
            `String "subscribe";
            `String (Path.absolute root);
            `String "pyre_file_change_subscription";
            `Assoc
              [
                "empty_on_fresh_instance", `Bool true;
                ( "expression",
                  `List
                    [
                      `String "allof";
                      `List [`String "type"; `String "f"];
                      `List (`String "anyof" :: List.append suffixes base_names);
                    ] );
                "fields", `List [`String "name"];
              ];
          ]
      in
      Raw.Connection.send connection request
      >>= fun () ->
      Raw.Connection.receive connection ()
      >>= function
      | Raw.Response.Error message -> raise (SubscriptionError message)
      | Raw.Response.EndOfStream ->
          raise (SubscriptionError "Cannot get the initial response from `watchman subscribe`")
      | Raw.Response.Ok initial_response -> (
          match Yojson.Safe.Util.member "error" initial_response with
          | `Null -> (
              match Yojson.Safe.Util.member "clock" initial_response with
              | `String initial_clock -> Lwt.return { connection; initial_clock }
              | _ as error ->
                  let message =
                    Format.sprintf
                      "Cannot determinte the initial clock from response %s"
                      (Yojson.Safe.to_string error)
                  in
                  raise (SubscriptionError message) )
          | _ as error ->
              let message =
                Format.sprintf
                  "Subscription rejected by watchman. Response: %s"
                  (Yojson.Safe.to_string error)
              in
              raise (SubscriptionError message) )
    in
    Lwt.catch do_subscribe (fun exn ->
        (* Make sure the connection is properly shut down when an exception is raised. *)
        Raw.shutdown_connection connection >>= fun () -> raise exn)


  let listen ~f { connection; initial_clock } =
    let open Lwt.Infix in
    let rec do_listen () =
      Raw.Connection.receive connection ()
      >>= function
      | Raw.Response.Error message -> raise (SubscriptionError message)
      | Raw.Response.EndOfStream -> Lwt.return_unit
      | Raw.Response.Ok response -> (
          match
            ( Yojson.Safe.Util.member "is_fresh_instance" response,
              Yojson.Safe.Util.member "clock" response )
          with
          | `Bool true, `String update_clock when String.equal initial_clock update_clock ->
              (* This is the initial `is_fresh_instance` message, which can be safely ignored. *)
              do_listen ()
          | `Bool true, _ ->
              (* This is not the initial `is_fresh_instance` message, which usually indicates that
                 our current view of the filesystem may not be accurate anymore. *)
              raise (SubscriptionError "Received `is_fresh_instance` message from watchman")
          | _, _ -> (
              try
                let root =
                  Yojson.Safe.Util.(member "root" response |> to_string)
                  |> Path.create_absolute ~follow_symbolic_links:false
                in
                let changed_paths =
                  Yojson.Safe.Util.(member "files" response |> convert_each to_string)
                  |> List.map ~f:(fun relative -> Path.create_relative ~root ~relative)
                in
                f changed_paths >>= fun () -> do_listen ()
              with
              | Yojson.Json_error message ->
                  let message =
                    Format.sprintf "Cannot parse JSON result from watchman subscription: %s" message
                  in
                  raise (SubscriptionError message) ) )
    in
    Lwt.finalize do_listen (fun () -> Raw.Connection.shutdown connection ())


  let with_subscription ~f config =
    let open Lwt.Infix in
    subscribe config >>= fun subscriber -> listen ~f subscriber
end
