import XCTest
@testable import Hydra

final class ClusterSSHConfigTests: XCTestCase {
    func testParsesSSHBlock() {
        let yaml = """
        agent:
          ai:
            always_consult: false
        ssh:
          user: dave
          private_key_path: ~/.ssh/id_ed25519
          port: 22
          timeout: 10
        """
        let r = ClusterSSHConfig.load(from: yaml)
        XCTAssertEqual(r?.user, "dave")
        XCTAssertEqual(r?.privateKeyPath, NSString(string: "~/.ssh/id_ed25519").expandingTildeInPath)
        XCTAssertEqual(r?.port, 22)
    }

    func testDefaultsPortTo22WhenMissing() {
        let yaml = "ssh:\n  user: bob\n  private_key_path: /home/bob/.ssh/id_rsa\n"
        let r = ClusterSSHConfig.load(from: yaml)
        XCTAssertEqual(r?.port, 22)
        XCTAssertEqual(r?.user, "bob")
    }

    func testReturnsNilWhenNoUser() {
        XCTAssertNil(ClusterSSHConfig.load(from: "devices: []\n"))
    }
}
