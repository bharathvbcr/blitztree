# Provider pipeline test

Runs the real shipping code (`app/PlanParsing.swift` + `app/ModelProvider.swift`)
against a local mock endpoint, covering the shapes real models and endpoints
actually produce:

1. strict SSE stream (partial items stream before the plan)
2. markdown-fenced JSON
3. non-SSE plain JSON body (endpoint ignored `stream: true`)
4. HTTP error propagation
5. plain http to a remote host is refused before any request (loopback http,
   like this mock, is the one allowed exception)

`tests/run-cleanup.sh` runs it: the mock picks free loopback ports and writes
them to a file, which the harness reads. By hand:

    python3 tests/provider-pipeline/server.py "$DIR/ports.json" &
    swiftc -parse-as-library app/PlanParsing.swift app/ModelProvider.swift \
        tests/provider-pipeline/main.swift -o "$DIR/harness"
    "$DIR/harness" "$DIR/ports.json"

6. a redirect to another origin (host or port) is refused and the key and
   prompt never reach the second listener; a same-origin redirect is followed
