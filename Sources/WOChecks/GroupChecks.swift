import Foundation
import WindowOrganizerCore

private func group(_ id: String = "g1", _ name: String = "Work", screen: String? = "S1", desktops: [Int] = [1],
                   members: [ZoneMember] = [ZoneMember(bundleID: "com.a")], mode: GroupMode = .tiled) -> WindowGroup {
    WindowGroup(id: id, name: name, members: members, screen: screen, desktops: desktops, mode: mode)
}

private func encoded(_ l: Layouts) throws -> String {
    let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
    return String(decoding: try enc.encode(l), as: UTF8.self)
}

private func refused(_ l: Layouts, _ why: String) throws {
    do { try l.validate(); throw CheckFailure(description: "accepted: \(why)") }
    catch let e as LayoutStoreError { try expectEqual(e, .invalidLayout) }
}

private func with(_ g: WindowGroup) -> Layouts { var l = Layouts(); l.setGroup(g); return l }

private let position = GroupPosition(matcher: Matcher(bundleID: "com.a"), fraction: UnitRect(x: 0, y: 0, width: 0.5, height: 1))

let groupChecks: [(String, @Sendable () throws -> Void)] = [
    ("groups: a file without groups is written as schema 2 with no groups key", {
        let text = try encoded(Layouts())
        try expect(text.contains("\"schema\":2"), text)
        try expect(!text.contains("groups"), text)
        try expectEqual(try encoded(try LayoutStore.decode(Data(text.utf8))), text)
    }),
    ("groups: a group round-trips (app and window member, two desktops, both modes) and the file says schema 3", {
        var l = Layouts()
        l.setGroup(group("a", "Work", desktops: [1, 2], members: [ZoneMember(bundleID: "com.a"), ZoneMember(bundleID: "com.b", titlePattern: "Docs*")]))
        l.setGroup(group("b", "Chat", mode: .saved([position])))
        l.setGroup(group("c", "Loose", screen: nil, desktops: []))
        let text = try encoded(l)
        try expect(text.contains("\"schema\":3"), text)
        let back = try LayoutStore.decode(Data(text.utf8))
        try expectEqual(back.groups, l.groups)
        try expectEqual(try encoded(back), text)
    }),
    ("groups: a schema newer than the current one is refused", {
        let newer = Data("{\"schema\":\(Layouts.currentSchema + 1),\"setups\":{}}".utf8)
        do { _ = try LayoutStore.decode(newer); throw CheckFailure(description: "decoded") }
        catch let e as LayoutStoreError { try expectEqual(e, .newerSchema(Layouts.currentSchema + 1)) }
        try expectEqual(Layouts.currentSchema, 3)
    }),
    ("groups: setGroup replaces in place; removeGroup and moveGroup work, moveGroup clamped", {
        var l = Layouts()
        for id in ["a", "b", "c"] { l.setGroup(group(id, id.uppercased())) }
        l.setGroup(group("b", "Bee"))
        try expectEqual(l.groups.map(\.id), ["a", "b", "c"])
        try expectEqual(l.group(id: "b")?.name, "Bee")
        l.moveGroup(id: "a", to: 99)
        try expectEqual(l.groups.map(\.id), ["b", "c", "a"])
        l.moveGroup(id: "a", to: -5)
        try expectEqual(l.groups.map(\.id), ["a", "b", "c"])
        l.moveGroup(id: "c", to: 1)
        try expectEqual(l.groups.map(\.id), ["a", "c", "b"])
        l.moveGroup(id: "zz", to: 0)
        try expectEqual(l.groups.count, 3)
        l.removeGroup(id: "c"); l.removeGroup(id: "zz")
        try expectEqual(l.groups.map(\.id), ["a", "b"])
        try expect(l.group(id: "c") == nil, "removed")
    }),
    ("groups: groups(desktop:screen:) returns only assigned, matching groups in list order", {
        var l = Layouts()
        l.setGroup(group("a", "A", screen: "S1", desktops: [1, 2]))
        l.setGroup(group("b", "B", screen: "S2", desktops: [1]))
        l.setGroup(group("c", "C", screen: nil, desktops: []))
        l.setGroup(group("d", "D", screen: "S1", desktops: [2]))
        l.setGroup(group("e", "E", screen: "S1", desktops: []))
        try expectEqual(l.groups(desktop: 2, screen: "S1").map(\.id), ["a", "d"])
        try expectEqual(l.groups(desktop: 1, screen: "S1").map(\.id), ["a"])
        try expectEqual(l.groups(desktop: 1, screen: "S2").map(\.id), ["b"])
        try expectEqual(l.groups(desktop: 3, screen: "S1").map(\.id), [])
    }),
    ("groups: validation accepts a good group and refuses each bad one", {
        try with(group()).validate()
        try with(group(mode: .saved([position]))).validate()
        try with(group(screen: nil, desktops: [])).validate()
        var dupID = with(group("x", "One")); dupID.setGroup(group("y", "Two")); try dupID.validate()
        try refused(with(group("", "Work")), "empty id")
        var sameName = Layouts(); sameName.setGroup(group("a", "Work")); sameName.setGroup(group("b", "WORK"))
        try refused(sameName, "case-duplicate name")
        try refused(with(group("g1", "")), "empty name")
        try refused(with(group("g1", "   ")), "blank name")
        try refused(with(group("g1", " Work")), "untrimmed name")
        try refused(with(group("g1", String(repeating: "x", count: 101))), "name over 100")
        try refused(with(group(members: [])), "no members")
        try refused(with(group(members: [ZoneMember(bundleID: "")])), "empty bundle id")
        try refused(with(group(members: [ZoneMember(bundleID: "a"), ZoneMember(bundleID: "a")])), "duplicate member")
        try refused(with(group(members: (0..<101).map { ZoneMember(bundleID: "app\($0)") })), "101 members")
        try refused(with(group(desktops: [1001])), "desktop 1001")
        try refused(with(group(desktops: [-1])), "desktop -1")
        try refused(with(group(desktops: [1, 1])), "duplicate desktops")
        try refused(with(group(screen: nil, desktops: [1])), "desktops without a screen")
        try refused(with(group(screen: "")), "empty screen")
        let outside = GroupPosition(matcher: Matcher(bundleID: "com.a"), fraction: UnitRect(x: 0.6, y: 0, width: 0.6, height: 1))
        try refused(with(group(mode: .saved([outside]))), "position outside the unit square")
        let stranger = GroupPosition(matcher: Matcher(bundleID: "com.zz"), fraction: position.fraction)
        try refused(with(group(mode: .saved([stranger]))), "position for a non-member")
        try refused(with(group(mode: .saved([position, position]))), "duplicate position")
        let negative = GroupPosition(matcher: Matcher(bundleID: "com.a", order: -1), fraction: position.fraction)
        try refused(with(group(mode: .saved([negative]))), "negative order")
        let g = #"{"id":"x","name":"NAME","members":[{"bundleID":"a"}],"desktops":[],"mode":{"mode":"tiled"}}"#
        let dup = "{\"schema\":3,\"setups\":{},\"groups\":[" + g.replacingOccurrences(of: "NAME", with: "One") + "," + g.replacingOccurrences(of: "NAME", with: "Two") + "]}"
        do { _ = try LayoutStore.decode(Data(dup.utf8)); throw CheckFailure(description: "decoded a duplicate id") }
        catch let e as LayoutStoreError { try expectEqual(e, .invalidLayout) }
        var many = Layouts(); for i in 0...Layouts.maxGroups { many.setGroup(group("g\(i)", "G\(i)")) }
        try refused(many, "201 groups")
    }),
    ("groups: an unknown mode string fails to decode", {
        let json = Data(#"{"id":"g","name":"W","members":[{"bundleID":"a"}],"desktops":[],"mode":{"mode":"fancy"}}"#.utf8)
        do { _ = try JSONDecoder().decode(WindowGroup.self, from: json); throw CheckFailure(description: "decoded") }
        catch is DecodingError {}
        let ok = Data(#"{"id":"g","name":"W","members":[{"bundleID":"a"}],"desktops":[],"mode":{"mode":"tiled"}}"#.utf8)
        try expectEqual(try JSONDecoder().decode(WindowGroup.self, from: ok).mode, .tiled)
    }),
    ("groups: decode, set an arrangement, encode keeps the groups", {
        var l = Layouts(); l.setGroup(group(mode: .saved([position])))
        var back = try LayoutStore.decode(Data(try encoded(l).utf8))
        back.set(ScreenArrangement(kind: .autoTile), setup: ScreenSetup(screens: []), desktop: 1, screen: "S1")
        let again = try LayoutStore.decode(Data(try encoded(back).utf8))
        try expectEqual(again.groups, l.groups)
        try expectEqual(again.arrangement(setup: ScreenSetup(screens: []), desktop: 1, screen: "S1")?.kind, .autoTile)
    }),
]
