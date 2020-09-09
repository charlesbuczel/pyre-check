/**
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *
 * @format
 */

import React from 'react';
import {Link} from 'react-router-dom';

class Issues extends React.Component {
  constructor(props) {
    super(props);
    this.fetchIssues = this.fetchIssues.bind(this);
  }

  fetchIssues() {
    const endCursor = this.props.data.issues.pageInfo.endCursor;
    this.props.fetchMore({
      variables: {after: endCursor},
      updateQuery: (prevResult, {fetchMoreResult}) => {
        fetchMoreResult.issues.edges = [
          ...prevResult.issues.edges,
          ...fetchMoreResult.issues.edges,
        ];
        return fetchMoreResult;
      },
    });
  }

  render() {
    return (
      <div>
        <h2>Issues</h2>
        {this.props.data.issues.edges.map(({node}) => (
          <div className="issue_instance">
            <h3>Issue {node.issue_id}</h3>
            <p>Code: {node.code}</p>
            <p>Message: {node.message}</p>
            <p>Callable: {node.callable}</p>
            <p>
              Location: {node.filename}:{node.location}
            </p>
            <div id="trace_lengths">
              <strong>Min Trace Lengths</strong>
              <p>Sources: {node.min_trace_length_to_sources}</p>
              <p>Sinks: {node.min_trace_length_to_sinks}</p>
            </div>
            <br />
            <Link to={`/trace/${node.issue_id}`}>
              <button>See Trace >></button>
            </Link>
          </div>
        ))}
        <button onClick={this.fetchIssues}>More</button>
      </div>
    );
  }
}

export default Issues;
