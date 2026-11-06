import Testing
@testable import KidicomKit

@Test("Display DICOM person names", arguments: [
    ("SILVA^MARIA^C", "Silva, Maria C"),
    ("SILVA^MARIA", "Silva, Maria"),
    ("SILVA", "Silva"),
    ("^MARIA", "Maria"),
    ("", ""),
    ("^^", ""),
    ("McDonald^Ann", "McDonald, Ann"),
    ("YAMADA^TARO=山田^太郎", "Yamada, Taro"),
])
func displays(_ raw: String, expected: String) {
    #expect(PersonName.display(raw) == expected)
}
