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

    func testStripsQuotedValues() {
        let yaml = """
        ssh:
          user: "dave"
          private_key_path: "~/.ssh/id_ed25519"
          port: 22
        """
        let r = ClusterSSHConfig.load(from: yaml)
        XCTAssertEqual(r?.user, "dave")
        XCTAssertEqual(r?.privateKeyPath, NSString(string: "~/.ssh/id_ed25519").expandingTildeInPath)
    }

    func testEmptyQuotedUserReturnsNil() {
        let yaml = "ssh:\n  user: \"\"\n  private_key_path: \"~/.ssh/id_rsa\"\n"
        XCTAssertNil(ClusterSSHConfig.load(from: yaml))
    }

    func testTopLevelSSHOnly() {
        let yaml = """
        agent:
          ssh:
            user: nested-bad
            private_key_path: /bad/path
        ssh:
          user: real
          private_key_path: /home/real/.ssh/id_rsa
          port: 2200
        """
        let r = ClusterSSHConfig.load(from: yaml)
        XCTAssertEqual(r?.user, "real")
        XCTAssertEqual(r?.privateKeyPath, "/home/real/.ssh/id_rsa")
        XCTAssertEqual(r?.port, 2200)
    }

    func testTrailingCommentOnPort() {
        let yaml = "ssh:\n  user: dave\n  private_key_path: /home/dave/.ssh/id_rsa\n  port: 2222 # custom\n"
        let r = ClusterSSHConfig.load(from: yaml)
        XCTAssertEqual(r?.port, 2222)
    }

    func testConfigFileURLHonorsEnvOverride() {
        let hydraDir = ClusterSSHConfig.configDir(env: ["HYDRA_CONFIG_DIR": "/tmp/hydra-override", "NAGA_CONFIG_DIR": "/tmp/naga-override"])
        XCTAssertEqual(hydraDir, "/tmp/hydra-override")

        let nagaDir = ClusterSSHConfig.configDir(env: ["NAGA_CONFIG_DIR": "/tmp/naga-override"])
        XCTAssertEqual(nagaDir, "/tmp/naga-override")

        let defaultDir = ClusterSSHConfig.configDir(env: [:])
        XCTAssertTrue(defaultDir.hasSuffix("/.hydra"))

        let url = ClusterSSHConfig.configFileURL()
        XCTAssertTrue(url.path.hasSuffix("config.yaml"))
    }
}
