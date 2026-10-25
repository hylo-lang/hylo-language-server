import Foundation

enum MessageFramingError: Error {
	case malformedData
	case missingField
	case contentLengthMissing
}

struct MessageFraming {
	public static func frame(_ data: Data) -> Data {
		let length = data.count

		let header = "Content-Length: \(length)\r\n\r\n"
		let headerData = Data(header.utf8)

		return headerData + data
	}

	public static func readHeader(_ value: String) throws -> (String, String) {
		let components = value.components(separatedBy: ":")
		let name = components[0].trimmingWhitespace()
		let value = components[1].trimmingWhitespace()

		return (name, value)
	}
}

extension String {
	/// Returns `self` without leading and trailing tabs and space separators.
	///
	/// This is equivalent to `trimmingCharacters(in: .whitespaces)`, which is only available with
	/// the full Foundation, not with FoundationEssentials. Like `CharacterSet.whitespaces`, it
	/// treats U+200B ZERO WIDTH SPACE as whitespace.
	fileprivate func trimmingWhitespace() -> String {
		let isWhitespace = { (u: Unicode.Scalar) in
			u == "\t" || u == "\u{200B}" || u.properties.generalCategory == .spaceSeparator
		}

		guard let start = unicodeScalars.firstIndex(where: { !isWhitespace($0) }) else { return "" }
		let end = unicodeScalars.lastIndex(where: { !isWhitespace($0) })!

		return String(unicodeScalars[start...end])
	}
}
