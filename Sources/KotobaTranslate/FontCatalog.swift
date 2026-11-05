import AppKit

struct FontFace: Identifiable {
    /// The exact PostScript name, rather than a synthetic weight applied to a family.
    let id: String
    let label: String
    let weight: Int
    let traits: NSFontTraitMask
}

@MainActor
enum FontCatalog {
    private static var cache: [String: [FontFace]] = [:]

    private static func resolvedFamily(_ family: String) -> String {
        family.isEmpty ? NSFont.systemFont(ofSize: 16).familyName ?? family : family
    }

    static func faces(for family: String) -> [FontFace] {
        let family = resolvedFamily(family)
        if let cached = cache[family] { return cached }
        let members = NSFontManager.shared.availableMembers(ofFontFamily: family) ?? []
        let faces = members.compactMap { member -> FontFace? in
            guard member.count >= 4,
                  let name = member[0] as? String,
                  let label = member[1] as? String,
                  let weight = member[2] as? NSNumber,
                  let traits = member[3] as? NSNumber,
                  NSFont(name: name, size: 16) != nil else { return nil }
            return FontFace(id: name, label: label, weight: weight.intValue,
                            traits: NSFontTraitMask(rawValue: traits.uintValue))
        }.sorted {
            if $0.weight != $1.weight { return $0.weight < $1.weight }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
        cache[family] = faces
        return faces
    }

    static func selectedFace(family: String, name: String) -> FontFace? {
        let faces = faces(for: family)
        if let face = faces.first(where: { $0.id == name }) { return face }
        let preferred = family.isEmpty ? NSFont.systemFont(ofSize: 16) :
            NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 16)
        return faces.first(where: { $0.id == preferred?.fontName }) ?? faces.first
    }
}
