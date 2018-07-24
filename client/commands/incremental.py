# Copyright (c) 2016-present, Facebook, Inc.
#
# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

import atexit
import logging
import os
import subprocess
import sys

from .. import FAILURE, SUCCESS
from .command import ClientException, ErrorHandling, State
from .start import Start
from .stop import Stop


LOG = logging.getLogger(__name__)


class Incremental(ErrorHandling):
    NAME = "incremental"

    def __init__(self, arguments, configuration, source_directory) -> None:
        super(Incremental, self).__init__(arguments, configuration, source_directory)

    # pyre-ignore: T31696900
    def _read_stderr(self, _stream, source_directory) -> None:
        stderr_file = os.path.join(source_directory, ".pyre/server/server.stdout")
        with subprocess.Popen(
            ["tail", "-f", stderr_file],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
        ) as stderr_tail:
            atexit.register(stderr_tail.terminate)
            super(Incremental, self)._read_stderr(stderr_tail.stdout, source_directory)

    def _run(self) -> int:
        if self._state() == State.DEAD:
            LOG.warning("Starting server at `%s`.", self._source_directory)
            arguments = self._arguments
            arguments.terminal = False
            arguments.no_watchman = False
            Start(arguments, self._configuration, self._source_directory).run()

        flags = self._flags()
        flags.extend(
            [
                "-typeshed",
                str(self._configuration.get_typeshed()),
                "-expected-binary-version",
                str(self._configuration.get_version_hash()),
            ]
        )

        search_path = self._configuration.get_search_path()
        if search_path:
            flags.extend(["-search-path", ",".join(search_path)])

        if self._state() != State.DEAD:
            LOG.info("Waiting for server...")

        result = self._call_client(command=self.NAME, flags=flags)

        try:
            result.check()
            errors = self._get_errors(result)
            self._print(errors)
        except ClientException as exception:
            LOG.error("Error while waiting for server.")
            LOG.error("Run `%s restart` in order to restart the server.", sys.argv[0])
            return FAILURE

        return SUCCESS
