import Foundation

print("SonyProtocolKit — protocol conformance suite\n")

runFramingTests()
runCommandsTests()
runPayloadParserTests()
runFrameReassemblerTests()

exit(Harness.summary())
