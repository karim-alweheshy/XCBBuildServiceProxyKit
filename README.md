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

An evaluated-settings probe is available only when both
`XCBPROXY_SETTINGS_PROBE_MANIFEST_PATH` and
`XCBPROXY_SETTINGS_PROBE_REPORT_PATH` name explicit files. The manifest must
use rules_xcodeproj schema v2. The report path must not exist; the proxy creates
it exclusively with mode 0600. For the first `CREATE_BUILD`, the probe asks the
native service to evaluate the fixed build-plan roles plus the manifest's
`environmentKeys`, then forwards the original request bytes unchanged whether
the probe succeeds or fails. The report contains setting names, non-empty
presence, UTF-8 byte lengths, and SHA-256 digests, never setting values.
`TOOLCHAINS` is evaluated separately as its declared string-list macro and is
canonicalized with Swift Build's space-joined shell-environment convention; it
is never included in the scalar expression batch.

The Xcode bridge alone uses the unmodified public `SWBProtocol` and `SWBUtil`
products from Swift Build commit
`e4f6fc77ebe727657dadfedf50462f5a1a626ead`. The transport core has no Swift
Build dependency, and this probe does not intercept or launch Bazel.

This target intentionally contains no Bazel interception, protocol model, or
project-selection behavior. It is the reversible pass-through feasibility gate
for a future modern proxy.

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
