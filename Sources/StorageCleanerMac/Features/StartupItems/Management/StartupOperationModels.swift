import Foundation

extension StartupItemsDomain {
    enum StartupOperationKind: String, Codable, Hashable, Sendable {
        case disable
        case enable
        case stopCurrentSession
    }

    struct StartupOperationCommand: Codable, Equatable, Sendable {
        let executableURL: URL
        let arguments: [String]
        let timeout: TimeInterval
    }

    struct StartupExecutableIdentity: Codable, Equatable, Sendable {
        let teamIdentifier: String?
        let signingIdentifier: String?
        let designatedRequirement: String?

        init(_ inspection: StartupSignatureInspection) {
            teamIdentifier = inspection.teamIdentifier
            signingIdentifier = inspection.signingIdentifier
            designatedRequirement = inspection.designatedRequirement
        }
    }

    struct StartupOperationIdentityBinding: Codable, Equatable, Sendable {
        let executableURL: URL
        let executableIdentity: StartupExecutableIdentity
        let parentApplicationURL: URL?
        let parentApplicationIdentity: StartupExecutableIdentity?
    }

    struct StartupOperationPlan: Identifiable, Equatable, Sendable {
        let id: UUID
        let itemID: String
        let kind: StartupOperationKind
        let label: String
        let plistURL: URL
        let userID: uid_t
        let domain: String
        let serviceTarget: String
        let requiresAdministrator: Bool
        /// SHA-256 of the exact plist bytes shown in the confirmation preview.
        /// `perform` refuses to act if those bytes change before launchctl runs.
        let plistContentDigest: String
        let resolvedExecutableURL: URL
        let observedState: State
        let identityBinding: StartupOperationIdentityBinding?
        let commands: [StartupOperationCommand]
        let impactSummary: String
        let warnings: [String]

        init(
            id: UUID = UUID(),
            itemID: String,
            kind: StartupOperationKind,
            label: String,
            plistURL: URL,
            userID: uid_t,
            domain: String? = nil,
            requiresAdministrator: Bool = false,
            plistContentDigest: String,
            resolvedExecutableURL: URL,
            observedState: State,
            identityBinding: StartupOperationIdentityBinding? = nil,
            commands: [StartupOperationCommand],
            impactSummary: String,
            warnings: [String]
        ) {
            self.id = id
            self.itemID = itemID
            self.kind = kind
            self.label = label
            self.plistURL = plistURL
            self.userID = userID
            self.domain = domain ?? "gui/\(userID)"
            serviceTarget = "\(self.domain)/\(label)"
            self.requiresAdministrator = requiresAdministrator
            self.plistContentDigest = plistContentDigest
            self.resolvedExecutableURL = resolvedExecutableURL
            self.observedState = observedState
            self.identityBinding = identityBinding
            self.commands = commands
            self.impactSummary = impactSummary
            self.warnings = warnings
        }

        func bindingIdentity(_ binding: StartupOperationIdentityBinding) -> StartupOperationPlan {
            StartupOperationPlan(
                id: id,
                itemID: itemID,
                kind: kind,
                label: label,
                plistURL: plistURL,
                userID: userID,
                domain: domain,
                requiresAdministrator: requiresAdministrator,
                plistContentDigest: plistContentDigest,
                resolvedExecutableURL: resolvedExecutableURL,
                observedState: observedState,
                identityBinding: binding,
                commands: commands,
                impactSummary: impactSummary,
                warnings: warnings
            )
        }
    }

    struct StartupOperationResult: Sendable {
        let plan: StartupOperationPlan
        let verifiedState: State
        let undoRecordID: UUID?
    }

    enum StartupManagementError: Error, Equatable, LocalizedError, Sendable {
        case unsupported(String)
        case invalidLabel
        case invalidPlistPath
        case unsafePlistPermissions
        case startupConfigurationChanged
        case startupIdentityChanged
        case startupStateChanged
        case processFailed(arguments: [String], status: Int32, output: String)
        case verificationFailed(expected: StartupOperationKind, observed: State)
        case stateUnavailable(String)
        case undoRecordMismatch
        case undoRecordNotFound
        case persistenceFailed(String)
        case privilegedHelperFailed(String)

        var errorDescription: String? {
            switch self {
            case let .unsupported(reason):
                L10n.text(
                    "此启动项不能直接管理：\(reason)",
                    "Startup item cannot be managed directly: \(reason)"
                )
            case .invalidLabel:
                L10n.text("launchd 标签缺失或无效。", "The launchd label is missing or invalid.")
            case .invalidPlistPath:
                L10n.text(
                    "此启动项不在当前用户的 LaunchAgents 目录中。",
                    "The launch agent is outside the current user's LaunchAgents directory."
                )
            case .unsafePlistPermissions:
                L10n.text(
                    "此启动项配置的所有者或权限不安全。",
                    "The launch agent property list has unsafe ownership or permissions."
                )
            case .startupConfigurationChanged:
                L10n.text(
                    "启动项配置在确认后发生变化，操作已取消，请重新扫描。",
                    "The startup configuration changed after confirmation. Rescan before trying again."
                )
            case .startupIdentityChanged:
                L10n.text(
                    "启动项的可执行文件或签名身份发生变化，操作已阻止。",
                    "The startup executable or signing identity changed, so the operation was blocked."
                )
            case .startupStateChanged:
                L10n.text(
                    "启动项状态在确认后发生变化，操作已取消，请重新确认。",
                    "The startup state changed after confirmation. Review the operation again."
                )
            case let .processFailed(_, status, output):
                L10n.text(
                    "launchctl 执行失败（状态 \(status)）：\(output)",
                    "launchctl failed with status \(status): \(output)"
                )
            case .verificationFailed:
                L10n.text(
                    "操作后 launchd 未报告预期状态。",
                    "launchd did not report the requested state after the operation."
                )
            case let .stateUnavailable(detail):
                L10n.text(
                    "无法验证 launchd 状态：\(detail)",
                    "The launchd state could not be verified: \(detail)"
                )
            case .undoRecordMismatch:
                L10n.text(
                    "启动项与保存的撤销记录不再匹配。",
                    "The startup item no longer matches the saved undo record."
                )
            case .undoRecordNotFound:
                L10n.text("撤销记录不存在。", "The undo record no longer exists.")
            case let .persistenceFailed(detail):
                L10n.text(
                    "无法保存撤销记录：\(detail)",
                    "The undo record could not be persisted: \(detail)"
                )
            case let .privilegedHelperFailed(detail):
                L10n.text(
                    "管理员辅助程序未能完成启动项操作：\(detail)",
                    "The administrator helper could not complete the startup-item operation: \(detail)"
                )
            }
        }
    }
}
