import SwiftUI

struct UnavailableStateView: View {
    let title: String
    let systemImage: String
    let description: String?
    let imageFont: Font
    let titleFont: Font
    let descriptionFont: Font
    let titleColor: Color

    init(
        _ title: String,
        systemImage: String,
        description: String? = nil,
        imageFont: Font = .title2,
        titleFont: Font = .headline,
        descriptionFont: Font = .caption,
        titleColor: Color = .secondary
    ) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.imageFont = imageFont
        self.titleFont = titleFont
        self.descriptionFont = descriptionFont
        self.titleColor = titleColor
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(imageFont)
                .foregroundColor(.secondary)

            Text(title)
                .font(titleFont)
                .foregroundColor(titleColor)

            if let description, !description.isEmpty {
                Text(description)
                    .font(descriptionFont)
                    .foregroundColor(.secondary)
            }
        }
    }
}
