# XCBBuildServiceProxyKit

XCBBuildServiceProxyKit is a framework that enables you to write a proxy for
Xcode's XCBBuildService, which enables you to extend or replace Xcode's build
system.

## Usage

Check out the [Examples](Examples/).

### Modern native pass-through gate

`ModernBuildServiceProxy` is an opt-in, protocol-opaque pass-through service
for Xcode 26.5 build 17F42. It resolves the native `SWBBuildService` from the
selected Xcode, validates the exact Xcode build before launch, removes build
service override variables from the child's environment, and relays stdin and
stdout without decoding or rewriting messages.

Each output descriptor has exactly one serialized frame sink shared by its
forwarding pump and by router injections in either direction. A sink owns the
whole header-plus-payload transaction, including bounded streaming and partial
write retries, so concurrent output cannot interleave frame bytes. The first
sink failure is latched, rejects later sends, and stops the relay and its owned
native process group.

Build it with:

```sh
swift build --product ModernBuildServiceProxy
```

Use the resulting executable as `XCBBUILDSERVICE_PATH` for a single
`xcodebuild` or separately launched Xcode process. Keep `DEVELOPER_DIR` pinned
to Xcode 26.5. An unsupported Xcode build exits before launching any service.
Unset `XCBBUILDSERVICE_PATH` to return immediately to the native service.

Set `XCBPROXY_METADATA_PATH` to a new path in an existing private directory to
record one metadata-only JSON line per completed frame. The proxy creates the
file exclusively with mode 0600 and refuses to overwrite an existing path.
Records contain only direction, sequence, channel, payload length, the leading
MessagePack message-name string when safely recognizable, and payload SHA-256.
Payload bytes and environment values are never recorded.
This schema still describes ingress frames only. Output disposition and
injected-frame metadata are intentionally deferred to the owned-operation
evidence slice.

An evaluated-settings probe is available only when both
`XCBPROXY_SETTINGS_PROBE_MANIFEST_PATH` and
`XCBPROXY_SETTINGS_PROBE_REPORT_PATH` name explicit files. The manifest must
use rules_xcodeproj schema v2. The report path must not exist; the proxy creates
it exclusively with mode 0600. For the first `CREATE_BUILD`, the probe asks the
native service to evaluate the fixed build-plan roles plus the manifest's
`environmentKeys`, then forwards the original request bytes unchanged whether
the probe succeeds or fails. The report contains setting names, non-empty
presence, UTF-8 byte lengths, and SHA-256 digests, never setting values.
The bridge makes one target-scoped exported-settings request per target on a
distinct proxy-owned channel in the high half of the `UInt64` channel space.
It skips every observed channel and never reuses the original `CREATE_BUILD`
request or response channel. The service constructs the response with its
shell-script task-environment semantics. The bridge immediately projects it
onto the fixed/manifest allowlist; unknown exported settings never enter the
report. Every fixed plan role must be non-empty, while an unexported manifest
environment key is represented as absent/empty.

The Xcode bridge uses the unmodified public `SWBProtocol` and `SWBUtil`
products from Swift Build commit
`e4f6fc77ebe727657dadfedf50462f5a1a626ead`. The transport core has no Swift
Build dependency. No Swift Build fork or upstream change is required.

### Bazel operation routing

`ModernBuildServiceProxy` enables Bazel routing only when the launcher supplies
all three of these variables:

- `SWIFTBUILD_BAZEL_PROXY_MANIFEST`: the schema-v2 manifest inside the generated
  `.xcodeproj` integration directory
- `SWIFTBUILD_BAZEL_PROXY_MANIFEST_SHA256`: the lowercase SHA-256 of the exact
  manifest bytes
- `SWIFTBUILD_BAZEL_PROXY_PROJECT_IDENTITY`: the generated project's manifest
  identity

An incomplete tuple or mismatched digest fails before the native service is
launched. With no tuple, the executable remains an exact native pass-through.

For each `CREATE_BUILD`, the router asks the unmodified native service for the
public target-scoped exported-settings response. It then makes one operation-wide
decision:

- every requested target resolves to the verified manifest: own the operation
  and execute its generated Bazel adapter;
- the project, action, or target set is clearly unrelated or unsupported:
  forward the original CREATE bytes to the native service;
- evaluated identity or required settings disagree: return a deterministic
  registration error on the event channel and CREATE request channel.

The adapter receives no arguments. It reads newline-delimited labels, target
IDs, and output groups from `SWIFTBUILD_BAZEL_PROXY_REQUEST_DIR`, writes Bazel 9
JSON BEP to `SWIFTBUILD_BAZEL_PROXY_BEP_PATH`, and atomically publishes a
schema-v1 invocation receipt at
`SWIFTBUILD_BAZEL_PROXY_INVOCATION_RECEIPT`. The proxy validates the process
result, BEP terminal state, receipt, and declared product trees before
transactionally materializing products into Xcode's evaluated build directory.
Clean bypasses the adapter; index builds validate the adapter result but do not
materialize products.

Owned operations use reserved negative IDs, emit the public Swift Build
lifecycle in native order, serialize every injected/forwarded frame per output,
and produce exactly one terminal result. Cancellation is linearized with both
executor completion and product publication: a pre-commit cancellation reports
cancelled without changing products, while a completed product commit reports
success. Session DELETE waits for owned and resolving work to quiesce before the
original DELETE is forwarded.

## Future Improvements

- [ ] Add tests
- [ ] Use `Codable` for XCBProtocol parsing
- [ ] Use [Swift Service Lifecycle](https://github.com/swift-server/swift-service-lifecycle)

## Updating to Support New Xcode Versions

Check out [our guide](Docs/UPDATING.md).

## Recognition

- [jerrymarino/xcbuildkit](https://github.com/jerrymarino/xcbuildkit) for
  initial inspiration
- [a2/MessagePack.swift](https://github.com/a2/MessagePack.swift) for starting
  point of MessagePack parsing
