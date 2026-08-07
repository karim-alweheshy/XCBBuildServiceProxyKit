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
