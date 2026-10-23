//
//  EDXPeriodicTable.swift
//  Role: the element control of the EDS room: MacEMUI's `PeriodicTable` answered from the session. A click picks an element to quantify or takes a picked one out; a right-click gives its role
//        (Quantify, Fit only, Off) and the line families with their lines. There are no element rows under the table: everything an element can be told is on its cell. Presentation only:
//        the picks are `EDXSession`'s, what can be picked is `EDXElements.unavailableReason`, the menu's lines are `EDXElements.lineFamilies`.
//

import ShellSpectroscopy
import SwiftUI
import SpectroEDX
#if canImport(TEMCore)
import TEMCore
import TEMSession
#endif

enum EDXPeriodicActions {
    /// The table's questions and changes, answered from `session`; nothing is picked before a spectrum image is open.
    static func make(_ session: EDXSession) -> PeriodicTableActions {
        func symbol(_ z: Int) -> String { PeriodicTableGrid.symbol(z) }
        func pick(_ z: Int) -> EDXPick? { session.picks.first { $0.symbol == symbol(z) } }
        return PeriodicTableActions(
            state: { z in
                if let reason = EDXElements.unavailableReason(symbol: symbol(z)) { return .unavailable(reason) }
                guard let pick = pick(z) else { return .off }
                return pick.role == .quantify ? .quantify : .fitOnly
            },
            role: { z in pick(z).map { $0.role == .quantify ? ElementRoleChoice.quantify : .fitOnly } ?? .off },
            click: { z in session.toggle(symbol(z)) },
            setRole: { z, role in
                switch role {
                case .off: if pick(z) != nil { session.toggle(symbol(z)) }
                case .quantify, .fitOnly:
                    if pick(z) == nil { session.toggle(symbol(z)) }
                    session.setRole(role == .quantify ? .quantify : .fitOnly, of: symbol(z))
                }
            },
            families: { z in
                EDXElements.lineFamilies(symbol: symbol(z), pick: pick(z)).map { f in
                    ElementLineFamily(family: f.family.rawValue, isSelected: f.isSelected, lines: f.lines.map { ElementLineChoice(id: $0.id, title: $0.title, isChecked: $0.isChecked) })
                }
            },
            setFamily: { z, family in if let f = XRayFamily(rawValue: family) { session.setFamily(f, of: symbol(z)) } },
            toggleLine: { z, id in session.toggleLine(id, of: symbol(z)) },
            resetLines: { z in session.resetLines(of: symbol(z)) },
            hasChosenLines: { z in pick(z).map { $0.family != nil || !$0.lines.isEmpty } ?? false },
            mapped: { session.picks.filter { $0.role == .quantify }.compactMap { EDXElements.z(of: $0.symbol) } })
    }
}

struct EDXPeriodicTable: View {
    let session: EDXSession

    var body: some View {
        PeriodicTable(actions: EDXPeriodicActions.make(session))
            .disabled(!session.hasImage)
            .accessibilityIdentifier("edx.periodicTable")
    }
}
