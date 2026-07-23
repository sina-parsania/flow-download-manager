// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

@objc(DMProjectSnapshot)
public final class ProjectSnapshot: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let id: String
    public let name: String
    public let colorRole: String?

    public init(id: String, name: String, colorRole: String?) {
        self.id = id
        self.name = name
        self.colorRole = colorRole
    }

    public required init?(coder: NSCoder) {
        let id = coder.decodeObject(of: NSString.self, forKey: "id")
        let name = coder.decodeObject(of: NSString.self, forKey: "name")
        let colorRole = coder.decodeObject(of: NSString.self, forKey: "colorRole")
        guard let id, let name,
              UUID(uuidString: id as String) != nil,
              name.length > 0, name.length <= EngineXPC.maxPayloadStringLength
        else { return nil }
        if let colorRole, colorRole.length > 64 { return nil }
        self.id = id as String
        self.name = name as String
        self.colorRole = colorRole.map { $0 as String }
    }

    public func encode(with coder: NSCoder) {
        coder.encode(id as NSString, forKey: "id")
        coder.encode(name as NSString, forKey: "name")
        if let colorRole {
            coder.encode(colorRole as NSString, forKey: "colorRole")
        }
    }
}

@objc(DMTagSnapshot)
public final class TagSnapshot: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    public required init?(coder: NSCoder) {
        let id = coder.decodeObject(of: NSString.self, forKey: "id")
        let name = coder.decodeObject(of: NSString.self, forKey: "name")
        guard let id, let name,
              UUID(uuidString: id as String) != nil,
              name.length > 0, name.length <= EngineXPC.maxPayloadStringLength
        else { return nil }
        self.id = id as String
        self.name = name as String
    }

    public func encode(with coder: NSCoder) {
        coder.encode(id as NSString, forKey: "id")
        coder.encode(name as NSString, forKey: "name")
    }
}

@objc(DMListOrganizationResponse)
public final class ListOrganizationResponse: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let projects: [ProjectSnapshot]
    public let tags: [TagSnapshot]

    public init(requestID: String, projects: [ProjectSnapshot], tags: [TagSnapshot]) {
        self.requestID = requestID
        self.projects = projects
        self.tags = tags
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let projects = coder.decodeArrayOfObjects(ofClass: ProjectSnapshot.self, forKey: "projects")
        let tags = coder.decodeArrayOfObjects(ofClass: TagSnapshot.self, forKey: "tags")
        guard let requestID, let projects, let tags,
              UUID(uuidString: requestID as String) != nil,
              projects.count <= EngineXPC.maxCollectionCount,
              tags.count <= EngineXPC.maxCollectionCount
        else { return nil }
        self.requestID = requestID as String
        self.projects = projects
        self.tags = tags
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(projects as NSArray, forKey: "projects")
        coder.encode(tags as NSArray, forKey: "tags")
    }
}

@objc(DMUpsertProjectRequest)
public final class UpsertProjectRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let projectID: String
    public let name: String
    public let colorRole: String?

    public init(requestID: String, projectID: String, name: String, colorRole: String?) {
        self.requestID = requestID
        self.projectID = projectID
        self.name = name
        self.colorRole = colorRole
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let projectID = coder.decodeObject(of: NSString.self, forKey: "projectID")
        let name = coder.decodeObject(of: NSString.self, forKey: "name")
        let colorRole = coder.decodeObject(of: NSString.self, forKey: "colorRole")
        guard let requestID, let projectID, let name,
              UUID(uuidString: requestID as String) != nil,
              UUID(uuidString: projectID as String) != nil,
              name.length > 0, name.length <= EngineXPC.maxPayloadStringLength
        else { return nil }
        if let colorRole, colorRole.length > 64 { return nil }
        self.requestID = requestID as String
        self.projectID = projectID as String
        self.name = name as String
        self.colorRole = colorRole.map { $0 as String }
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(projectID as NSString, forKey: "projectID")
        coder.encode(name as NSString, forKey: "name")
        if let colorRole {
            coder.encode(colorRole as NSString, forKey: "colorRole")
        }
    }
}

@objc(DMUpsertProjectResponse)
public final class UpsertProjectResponse: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let projectID: String

    public init(requestID: String, projectID: String) {
        self.requestID = requestID
        self.projectID = projectID
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let projectID = coder.decodeObject(of: NSString.self, forKey: "projectID")
        guard let requestID, let projectID,
              UUID(uuidString: requestID as String) != nil,
              UUID(uuidString: projectID as String) != nil
        else { return nil }
        self.requestID = requestID as String
        self.projectID = projectID as String
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(projectID as NSString, forKey: "projectID")
    }
}

@objc(DMUpsertTagRequest)
public final class UpsertTagRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let tagID: String
    public let name: String

    public init(requestID: String, tagID: String, name: String) {
        self.requestID = requestID
        self.tagID = tagID
        self.name = name
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let tagID = coder.decodeObject(of: NSString.self, forKey: "tagID")
        let name = coder.decodeObject(of: NSString.self, forKey: "name")
        guard let requestID, let tagID, let name,
              UUID(uuidString: requestID as String) != nil,
              UUID(uuidString: tagID as String) != nil,
              name.length > 0, name.length <= EngineXPC.maxPayloadStringLength
        else { return nil }
        self.requestID = requestID as String
        self.tagID = tagID as String
        self.name = name as String
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(tagID as NSString, forKey: "tagID")
        coder.encode(name as NSString, forKey: "name")
    }
}

@objc(DMUpsertTagResponse)
public final class UpsertTagResponse: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let tagID: String

    public init(requestID: String, tagID: String) {
        self.requestID = requestID
        self.tagID = tagID
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let tagID = coder.decodeObject(of: NSString.self, forKey: "tagID")
        guard let requestID, let tagID,
              UUID(uuidString: requestID as String) != nil,
              UUID(uuidString: tagID as String) != nil
        else { return nil }
        self.requestID = requestID as String
        self.tagID = tagID as String
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(tagID as NSString, forKey: "tagID")
    }
}

@objc(DMSetJobTagsRequest)
public final class SetJobTagsRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let jobID: String
    public let tagIDs: [String]

    public init(requestID: String, jobID: String, tagIDs: [String]) {
        self.requestID = requestID
        self.jobID = jobID
        self.tagIDs = tagIDs
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let jobID = coder.decodeObject(of: NSString.self, forKey: "jobID")
        let tagIDs = coder.decodeArrayOfObjects(ofClass: NSString.self, forKey: "tagIDs")
        guard let requestID, let jobID, let tagIDs,
              UUID(uuidString: requestID as String) != nil,
              UUID(uuidString: jobID as String) != nil,
              tagIDs.count <= EngineXPC.maxCollectionCount,
              tagIDs.allSatisfy({ UUID(uuidString: $0 as String) != nil })
        else { return nil }
        self.requestID = requestID as String
        self.jobID = jobID as String
        self.tagIDs = tagIDs.map { $0 as String }
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(jobID as NSString, forKey: "jobID")
        coder.encode(tagIDs as NSArray, forKey: "tagIDs")
    }
}

@objc(DMSetJobTagsResponse)
public final class SetJobTagsResponse: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let jobID: String

    public init(requestID: String, jobID: String) {
        self.requestID = requestID
        self.jobID = jobID
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let jobID = coder.decodeObject(of: NSString.self, forKey: "jobID")
        guard let requestID, let jobID,
              UUID(uuidString: requestID as String) != nil,
              UUID(uuidString: jobID as String) != nil
        else { return nil }
        self.requestID = requestID as String
        self.jobID = jobID as String
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(jobID as NSString, forKey: "jobID")
    }
}

@objc(DMSetJobProjectRequest)
public final class SetJobProjectRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let jobID: String
    /// Nil clears the job's project assignment.
    public let projectID: String?

    public init(requestID: String, jobID: String, projectID: String?) {
        self.requestID = requestID
        self.jobID = jobID
        self.projectID = projectID
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let jobID = coder.decodeObject(of: NSString.self, forKey: "jobID")
        let projectID = coder.decodeObject(of: NSString.self, forKey: "projectID")
        guard let requestID, let jobID,
              UUID(uuidString: requestID as String) != nil,
              UUID(uuidString: jobID as String) != nil
        else { return nil }
        if let projectID, UUID(uuidString: projectID as String) == nil {
            return nil
        }
        self.requestID = requestID as String
        self.jobID = jobID as String
        self.projectID = projectID.map { $0 as String }
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(jobID as NSString, forKey: "jobID")
        if let projectID {
            coder.encode(projectID as NSString, forKey: "projectID")
        }
    }
}

@objc(DMSetJobProjectResponse)
public final class SetJobProjectResponse: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let jobID: String

    public init(requestID: String, jobID: String) {
        self.requestID = requestID
        self.jobID = jobID
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let jobID = coder.decodeObject(of: NSString.self, forKey: "jobID")
        guard let requestID, let jobID,
              UUID(uuidString: requestID as String) != nil,
              UUID(uuidString: jobID as String) != nil
        else { return nil }
        self.requestID = requestID as String
        self.jobID = jobID as String
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(jobID as NSString, forKey: "jobID")
    }
}

@objc(DMCategoryRuleSnapshot)
public final class CategoryRuleSnapshot: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let id: String
    public let priority: Int
    public let enabled: Bool
    public let predicateJSON: String
    public let categoryStableKey: String

    public init(
        id: String,
        priority: Int,
        enabled: Bool,
        predicateJSON: String,
        categoryStableKey: String
    ) {
        self.id = id
        self.priority = priority
        self.enabled = enabled
        self.predicateJSON = predicateJSON
        self.categoryStableKey = categoryStableKey
    }

    public required init?(coder: NSCoder) {
        let id = coder.decodeObject(of: NSString.self, forKey: "id")
        let predicateJSON = coder.decodeObject(of: NSString.self, forKey: "predicateJSON")
        let categoryStableKey = coder.decodeObject(of: NSString.self, forKey: "categoryStableKey")
        let enabled = coder.decodeBool(forKey: "enabled")
        let priority = coder.decodeInteger(forKey: "priority")
        guard let id, let predicateJSON, let categoryStableKey,
              UUID(uuidString: id as String) != nil,
              predicateJSON.length > 0, predicateJSON.length <= EngineXPC.maxPayloadStringLength,
              categoryStableKey.length > 0, categoryStableKey.length <= 64
        else { return nil }
        self.id = id as String
        self.priority = priority
        self.enabled = enabled
        self.predicateJSON = predicateJSON as String
        self.categoryStableKey = categoryStableKey as String
    }

    public func encode(with coder: NSCoder) {
        coder.encode(id as NSString, forKey: "id")
        coder.encode(priority, forKey: "priority")
        coder.encode(enabled, forKey: "enabled")
        coder.encode(predicateJSON as NSString, forKey: "predicateJSON")
        coder.encode(categoryStableKey as NSString, forKey: "categoryStableKey")
    }
}

@objc(DMListCategoryRulesResponse)
public final class ListCategoryRulesResponse: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let rules: [CategoryRuleSnapshot]

    public init(requestID: String, rules: [CategoryRuleSnapshot]) {
        self.requestID = requestID
        self.rules = rules
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let rules = coder.decodeArrayOfObjects(ofClass: CategoryRuleSnapshot.self, forKey: "rules")
        guard let requestID, let rules,
              UUID(uuidString: requestID as String) != nil,
              rules.count <= EngineXPC.maxCollectionCount
        else { return nil }
        self.requestID = requestID as String
        self.rules = rules
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(rules as NSArray, forKey: "rules")
    }
}

@objc(DMUpsertCategoryRuleRequest)
public final class UpsertCategoryRuleRequest: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let ruleID: String
    public let priority: Int
    public let enabled: Bool
    public let predicateJSON: String
    public let categoryStableKey: String

    public init(
        requestID: String,
        ruleID: String,
        priority: Int,
        enabled: Bool,
        predicateJSON: String,
        categoryStableKey: String
    ) {
        self.requestID = requestID
        self.ruleID = ruleID
        self.priority = priority
        self.enabled = enabled
        self.predicateJSON = predicateJSON
        self.categoryStableKey = categoryStableKey
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let ruleID = coder.decodeObject(of: NSString.self, forKey: "ruleID")
        let predicateJSON = coder.decodeObject(of: NSString.self, forKey: "predicateJSON")
        let categoryStableKey = coder.decodeObject(of: NSString.self, forKey: "categoryStableKey")
        let enabled = coder.decodeBool(forKey: "enabled")
        let priority = coder.decodeInteger(forKey: "priority")
        guard let requestID, let ruleID, let predicateJSON, let categoryStableKey,
              UUID(uuidString: requestID as String) != nil,
              UUID(uuidString: ruleID as String) != nil,
              predicateJSON.length > 0, predicateJSON.length <= EngineXPC.maxPayloadStringLength,
              categoryStableKey.length > 0, categoryStableKey.length <= 64
        else { return nil }
        self.requestID = requestID as String
        self.ruleID = ruleID as String
        self.priority = priority
        self.enabled = enabled
        self.predicateJSON = predicateJSON as String
        self.categoryStableKey = categoryStableKey as String
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(ruleID as NSString, forKey: "ruleID")
        coder.encode(priority, forKey: "priority")
        coder.encode(enabled, forKey: "enabled")
        coder.encode(predicateJSON as NSString, forKey: "predicateJSON")
        coder.encode(categoryStableKey as NSString, forKey: "categoryStableKey")
    }
}

@objc(DMUpsertCategoryRuleResponse)
public final class UpsertCategoryRuleResponse: NSObject, NSSecureCoding, @unchecked Sendable {
    public static var supportsSecureCoding: Bool {
        true
    }

    public let requestID: String
    public let ruleID: String

    public init(requestID: String, ruleID: String) {
        self.requestID = requestID
        self.ruleID = ruleID
    }

    public required init?(coder: NSCoder) {
        let requestID = coder.decodeObject(of: NSString.self, forKey: "requestID")
        let ruleID = coder.decodeObject(of: NSString.self, forKey: "ruleID")
        guard let requestID, let ruleID,
              UUID(uuidString: requestID as String) != nil,
              UUID(uuidString: ruleID as String) != nil
        else { return nil }
        self.requestID = requestID as String
        self.ruleID = ruleID as String
    }

    public func encode(with coder: NSCoder) {
        coder.encode(requestID as NSString, forKey: "requestID")
        coder.encode(ruleID as NSString, forKey: "ruleID")
    }
}
