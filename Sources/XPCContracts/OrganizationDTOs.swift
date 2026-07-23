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
