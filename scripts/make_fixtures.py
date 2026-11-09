#!/usr/bin/env python3
"""Generate synthetic winmail.dat (TNEF) fixtures for tests.

Usage: python3 -I scripts/make_fixtures.py <output-dir>
       python3 -I scripts/make_fixtures.py --demo <picture.png> <winmail.dat>

Writes basic.dat, html.dat and rtf-only.dat. The files follow MS-OXTNEF and
MS-OXRTFCP closely enough that the `tnef` CLI can unpack them, which the tests
use as an independent check.
"""
import struct
import sys
import zlib
from pathlib import Path

# --- TNEF attribute ids (type in high word, id in low word) ---------------
ATT_FROM = 0x00008000
ATT_SUBJECT = 0x00018004
ATT_DATE_SENT = 0x00038005
ATT_BODY = 0x0002800C
ATT_MSG_PROPS = 0x00069003
ATT_TNEF_VERSION = 0x00089006
ATT_OEM_CODEPAGE = 0x00069007
ATT_MESSAGE_CLASS = 0x00078008
ATT_ATTACH_RENDDATA = 0x00069002
ATT_ATTACH_TITLE = 0x00018010
ATT_ATTACH_DATA = 0x0006800F
ATT_ATTACHMENT = 0x00069005

LVL_MESSAGE = 1
LVL_ATTACHMENT = 2

# --- MAPI property types / ids --------------------------------------------
PT_LONG = 0x0003
PT_BOOLEAN = 0x000B
PT_STRING8 = 0x001E
PT_UNICODE = 0x001F
PT_SYSTIME = 0x0040
PT_BINARY = 0x0102

PR_BODY = 0x1000
PR_RTF_COMPRESSED = 0x1009
PR_BODY_HTML = 0x1013
PR_INTERNET_CPID = 0x3FDE
PR_ATTACH_LONG_FILENAME = 0x3707
PR_ATTACH_MIME_TAG = 0x370E
PR_DISPLAY_NAME = 0x3001

RTF_PREBUF = (
    b"{\\rtf1\\ansi\\mac\\deff0\\deftab720{\\fonttbl;}{\\f0\\fnil \\froman "
    b"\\fswiss \\fmodern \\fscript \\fdecor MS Sans SerifSymbolArialTimes New "
    b"RomanCourier{\\colortbl\\red0\\green0\\blue0\r\n\\par "
    b"\\pard\\plain\\f0\\fs20\\b\\i\\u\\tab\\tx"
)
assert len(RTF_PREBUF) == 207, len(RTF_PREBUF)


def attribute(level: int, att_id: int, data: bytes) -> bytes:
    checksum = sum(data) & 0xFFFF
    return struct.pack("<BII", level, att_id, len(data)) + data + struct.pack("<H", checksum)


def pad4(data: bytes) -> bytes:
    return data + b"\0" * (-len(data) % 4)


def prop_variable(ptype: int, pid: int, value: bytes) -> bytes:
    return struct.pack("<HHII", ptype, pid, 1, len(value)) + pad4(value)


def prop_long(pid: int, value: int) -> bytes:
    return struct.pack("<HHI", PT_LONG, pid, value)


def unicode_z(text: str) -> bytes:
    return (text + "\0").encode("utf-16-le")


def mapi_props(*props: bytes) -> bytes:
    return struct.pack("<I", len(props)) + b"".join(props)


def dtr(year, month, day, hour, minute, second, weekday) -> bytes:
    return struct.pack("<7H", year, month, day, hour, minute, second, weekday)


def renddata() -> bytes:
    # attachment type 1 = file, position 0xFFFFFFFF, no width/height, flags 0
    return struct.pack("<HIHHI", 1, 0xFFFFFFFF, 0, 0, 0)


def crc32_rtf(data: bytes) -> int:
    # MS-OXRTFCP CRC: standard table, initial value 0, no final xor.
    crc = 0
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ (0xEDB88320 if crc & 1 else 0)
    return crc


def compress_rtf(raw: bytes) -> bytes:
    """Greedy LZFu compressor (MS-OXRTFCP) that also uses back references."""
    history = bytearray(RTF_PREBUF)
    out = bytearray()
    pos = 0
    finished = False
    while not finished:
        control = 0
        chunk = bytearray()
        for bit in range(8):
            if pos >= len(raw):
                # end marker: reference pointing at the current write offset
                chunk += struct.pack(">H", (len(history) % 4096) << 4)
                control |= 1 << bit
                finished = True
                break
            best_len, best_off = 0, 0
            start = max(0, len(history) - 4095)
            for cand in range(start, len(history)):
                length = 0
                while length < 17 and pos + length < len(raw):
                    src = cand + length
                    byte = history[src] if src < len(history) else raw[pos + (src - len(history))]
                    if byte != raw[pos + length]:
                        break
                    length += 1
                if length > best_len:
                    best_len, best_off = length, cand % 4096
            if best_len >= 2:
                chunk += struct.pack(">H", (best_off << 4) | (best_len - 2))
                control |= 1 << bit
                history += raw[pos:pos + best_len]
                pos += best_len
            else:
                chunk.append(raw[pos])
                history.append(raw[pos])
                pos += 1
        out.append(control)
        out += chunk
    body = bytes(out)
    header = struct.pack("<IIII", len(body) + 12, len(raw), 0x75465A4C, crc32_rtf(body))
    return header + body


def tiny_png() -> bytes:
    width = height = 16
    rows = b"".join(b"\0" + b"\xd0\x30\x30" * width for _ in range(height))

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    ihdr = struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0)
    return b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(rows)) + chunk(b"IEND", b"")


def tnef(*attributes: bytes) -> bytes:
    header = struct.pack("<IH", 0x223E9F78, 0x1234)
    preamble = attribute(LVL_MESSAGE, ATT_TNEF_VERSION, struct.pack("<I", 0x00010000))
    preamble += attribute(LVL_MESSAGE, ATT_OEM_CODEPAGE, struct.pack("<II", 1252, 0))
    preamble += attribute(LVL_MESSAGE, ATT_MESSAGE_CLASS, b"IPM.Microsoft Mail.Note\0")
    return header + preamble + b"".join(attributes)


def file_attachment(short_name: str, long_name: str, mime: str, data: bytes) -> bytes:
    return (
        attribute(LVL_ATTACHMENT, ATT_ATTACH_RENDDATA, renddata())
        + attribute(LVL_ATTACHMENT, ATT_ATTACH_TITLE, short_name.encode("cp1252") + b"\0")
        + attribute(LVL_ATTACHMENT, ATT_ATTACH_DATA, data)
        + attribute(
            LVL_ATTACHMENT,
            ATT_ATTACHMENT,
            mapi_props(
                prop_variable(PT_UNICODE, PR_ATTACH_LONG_FILENAME, unicode_z(long_name)),
                prop_variable(PT_STRING8, PR_ATTACH_MIME_TAG, mime.encode("ascii") + b"\0"),
            ),
        )
    )


RTF_BODY = (
    b"{\\rtf1\\ansi\\ansicpg1252\\deff0{\\fonttbl{\\f0 Calibri;}}\r\n"
    b"\\pard Hello Lothar,\\par\\par Please find the report attached. "
    b"The report covers the report period and the report findings.\\par\r\n"
    b"Gr\\'fc\\'dfe\\par}\r\n"
)


def basic() -> bytes:
    return tnef(
        attribute(LVL_MESSAGE, ATT_SUBJECT, "Quarterly report – Übersicht".encode("cp1252") + b"\0"),
        attribute(LVL_MESSAGE, ATT_DATE_SENT, dtr(2026, 11, 9, 14, 30, 5, 1)),
        attribute(
            LVL_MESSAGE,
            ATT_MSG_PROPS,
            mapi_props(
                prop_long(PR_INTERNET_CPID, 1252),
                prop_variable(PT_BINARY, PR_RTF_COMPRESSED, compress_rtf(RTF_BODY)),
            ),
        ),
        file_attachment("GRUSSE~1.TXT", "Grüße & Übersicht.txt", "text/plain", "Hallo Welt – äöü\n".encode("utf-8")),
        file_attachment("CHART~1.PNG", "chart.png", "image/png", tiny_png()),
    )


def html() -> bytes:
    page = (
        "<html><body><p>Hi,</p><p>see <b>attached</b> sheet.</p>"
        '<img src="https://tracker.example.com/pixel.gif"><script>alert(1)</script>'
        '<p><a href="https://example.com/">link</a></p></body></html>'
    )
    return tnef(
        attribute(LVL_MESSAGE, ATT_SUBJECT, b"HTML body\0"),
        attribute(
            LVL_MESSAGE,
            ATT_MSG_PROPS,
            mapi_props(
                prop_variable(PT_BINARY, PR_BODY_HTML, page.encode("utf-8")),
                prop_variable(PT_UNICODE, PR_BODY, unicode_z("Hi, see attached sheet.")),
            ),
        ),
        file_attachment("SHEET.CSV", "sheet.csv", "text/csv", b"a,b\n1,2\n"),
    )


def rtf_only() -> bytes:
    return tnef(
        attribute(LVL_MESSAGE, ATT_SUBJECT, b"Only RTF\0"),
        attribute(LVL_MESSAGE, ATT_BODY, b"Plain legacy body\0"),
        attribute(
            LVL_MESSAGE,
            ATT_MSG_PROPS,
            mapi_props(prop_variable(PT_BINARY, PR_RTF_COMPRESSED, compress_rtf(RTF_BODY))),
        ),
    )


PR_ATTACH_METHOD = 0x3705
PR_ATTACH_DATA_OBJ = 0x3701
PT_OBJECT = 0x000D
ATTACH_OLE = 6
IID_ISTORAGE = bytes.fromhex("0b000000" "0000" "0000" "c000000000000046")  # {0000000B-0000-0000-C000-000000000046}
END_OF_CHAIN, FREE, FAT_SECTOR = 0xFFFFFFFE, 0xFFFFFFFF, 0xFFFFFFFD


def compound_file(streams: list[tuple[str, bytes]]) -> bytes:
    """Minimal MS-CFB v3 writer: 512-byte sectors, mini stream for streams < 4096 bytes."""
    sectors: list[bytes] = []
    fat: list[int] = []

    def allocate(data: bytes) -> int:
        if not data:
            return END_OF_CHAIN
        data += b"\0" * (-len(data) % 512)
        start = len(sectors)
        for index in range(0, len(data), 512):
            sectors.append(data[index:index + 512])
            fat.append(len(sectors) if index + 512 < len(data) else END_OF_CHAIN)
        return start

    mini_stream = bytearray()
    mini_fat: list[int] = []
    entries = []
    for name, data in streams:
        if len(data) < 4096:
            start = len(mini_stream) // 64
            padded = data + b"\0" * (-len(data) % 64)
            count = max(1, len(padded) // 64)
            mini_stream += padded or b"\0" * 64
            mini_fat += [start + i + 1 for i in range(count - 1)] + [END_OF_CHAIN]
            entries.append((name, 2, start, len(data)))
        else:
            entries.append((name, 2, allocate(data), len(data)))

    root_start = allocate(bytes(mini_stream))
    mini_fat_bytes = b"".join(struct.pack("<I", value) for value in mini_fat)
    mini_fat_start = allocate(mini_fat_bytes)

    def directory_entry(name, kind, start, size, child=FREE, right=FREE):
        encoded = (name + "\0").encode("utf-16-le")
        return (
            encoded.ljust(64, b"\0")
            + struct.pack("<HBBIII", len(encoded), kind, 1, FREE, right, child)
            + b"\0" * 16 + struct.pack("<I", 0) + b"\0" * 16
            + struct.pack("<IQ", start, size)
        )

    directory = directory_entry("Root Entry", 5, root_start, len(mini_stream), child=1)
    for index, (name, kind, start, size) in enumerate(entries, start=1):
        right = index + 1 if index < len(entries) else FREE
        directory += directory_entry(name, kind, start, size, right=right)
    directory_start = allocate(directory)

    fat_sector_count = 1
    while len(sectors) + fat_sector_count > fat_sector_count * 128:
        fat_sector_count += 1
    fat_sectors = list(range(len(sectors), len(sectors) + fat_sector_count))
    fat += [FAT_SECTOR] * fat_sector_count
    fat += [FREE] * (fat_sector_count * 128 - len(fat))
    fat_bytes = b"".join(struct.pack("<I", value) for value in fat)
    sectors += [fat_bytes[i:i + 512] for i in range(0, len(fat_bytes), 512)]

    header = (
        bytes.fromhex("d0cf11e0a1b11ae1") + b"\0" * 16
        + struct.pack("<HHHHH", 0x3E, 3, 0xFFFE, 9, 6) + b"\0" * 6
        + struct.pack("<IIIIIIIII", 0, fat_sector_count, directory_start, 0, 4096,
                      mini_fat_start, 1 if mini_fat else 0, END_OF_CHAIN, 0)
        + b"".join(struct.pack("<I", value) for value in fat_sectors)
        + struct.pack("<I", FREE) * (109 - len(fat_sectors))
    )
    assert len(header) == 512
    return header + b"".join(sectors)


def tiny_bmp(width: int = 40, height: int = 40) -> bytes:
    row = b"\x30\x80\xd0" * width
    row += b"\0" * (-len(row) % 4)
    pixels = row * height
    return (
        b"BM" + struct.pack("<IHHI", 54 + len(pixels), 0, 0, 54)
        + struct.pack("<IiiHHIIiiII", 40, width, height, 1, 24, 0, len(pixels), 2835, 2835, 0, 0)
        + pixels
    )


def ole10native(label: str, data: bytes) -> bytes:
    body = (
        struct.pack("<H", 2) + label.encode("cp1252") + b"\0"
        + b"C:\\Users\\me\\" + label.encode("cp1252") + b"\0"
        + struct.pack("<HH", 0, 3)
        + struct.pack("<I", 12) + b"C:\\tmp\\x.tx\0"
        + struct.pack("<I", len(data)) + data
    )
    return struct.pack("<I", len(body)) + body


PR_RENDERING_POSITION = 0x370B


def ole_attachment(title: str, container: bytes, position: int = 0xFFFFFFFF) -> bytes:
    return (
        attribute(LVL_ATTACHMENT, ATT_ATTACH_RENDDATA, struct.pack("<HIHHI", 2, 0xFFFFFFFF, 0, 0, 0))
        + attribute(LVL_ATTACHMENT, ATT_ATTACH_TITLE, title.encode("cp1252") + b"\0")
        + attribute(
            LVL_ATTACHMENT,
            ATT_ATTACHMENT,
            mapi_props(
                prop_long(PR_ATTACH_METHOD, ATTACH_OLE),
                prop_long(PR_RENDERING_POSITION, position),
                prop_variable(PT_OBJECT, PR_ATTACH_DATA_OBJ, IID_ISTORAGE + container),
            ),
        )
    )


def ole() -> bytes:
    picture = compound_file([("\x01Ole", b"\x01\x00\x00\x02" + b"\0" * 16), ("CONTENTS", tiny_bmp())])
    package = compound_file([("\x01Ole10Native", ole10native("notes.txt", b"embedded notes\n"))])
    # Outlook marks where an OLE attachment is shown with \objattph followed by one space of text.
    rtf = (
        b"{\\rtf1\\ansi\\ansicpg1252\\deff0{\\fonttbl{\\f0 Calibri;}}\r\n"
        b"\\pard Before the picture:\\par\r\n"
        b"{\\lang1024\\noproof\\objattph  }\\par\r\n"
        b"After the picture.\\par}\r\n"
    )
    return tnef(
        attribute(LVL_MESSAGE, ATT_SUBJECT, b"OLE objects\0"),
        attribute(LVL_MESSAGE, ATT_MSG_PROPS, mapi_props(prop_variable(PT_BINARY, PR_RTF_COMPRESSED, compress_rtf(rtf)))),
        ole_attachment("Untitled Attachment", picture, position=24),
        ole_attachment("Package", package),
    )


PR_CLIENT_SUBMIT_TIME = 0x0039
PR_SENT_REPRESENTING_NAME = 0x0042
PR_SENDER_EMAIL_ADDRESS = 0x0C1F


def prop_systime(pid: int, year, month, day, hour, minute) -> bytes:
    import datetime
    moment = datetime.datetime(year, month, day, hour, minute, tzinfo=datetime.timezone.utc)
    filetime = int((moment.timestamp() + 11_644_473_600) * 10_000_000)
    return struct.pack("<HHQ", PT_SYSTIME, pid, filetime)


def tiny_pdf(text: str) -> bytes:
    stream = f"BT /F1 24 Tf 72 720 Td ({text}) Tj ET".encode("latin-1")
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R "
        b"/Resources << /Font << /F1 5 0 R >> >> >>",
        b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    out = bytearray(b"%PDF-1.4\n")
    offsets = []
    for number, body in enumerate(objects, start=1):
        offsets.append(len(out))
        out += b"%d 0 obj\n" % number + body + b"\nendobj\n"
    xref = len(out)
    out += b"xref\n0 %d\n0000000000 65535 f \n" % (len(objects) + 1)
    out += b"".join(b"%010d 00000 n \n" % offset for offset in offsets)
    out += b"trailer\n<< /Size %d /Root 1 0 R >>\nstartxref\n%d\n%%%%EOF\n" % (len(objects) + 1, xref)
    return bytes(out)


def demo(picture: bytes) -> bytes:
    """The sample mail shown in the README screenshot."""
    rtf = (
        b"{\\rtf1\\ansi\\ansicpg1252\\deff0{\\fonttbl{\\f0\\fswiss Calibri;}}\\fs22\r\n"
        b"\\pard Hey!\\par\\par\r\n"
        b"Did you know you can look inside winmail.dat attachments right in Apple Mail? "
        b"Install {\\b TNEF Preview}, select the attachment and press the space bar:\\par\\par\r\n"
        b"{\\lang1024\\noproof\\objattph  }\\par\\par\r\n"
        b"You get the message text, every attachment, and pictures right where the sender put them "
        b"\\'96 no extra app, no saving, no converting. It never loads anything from the internet, "
        b"so tracking pixels stay quiet.\\par\\par\r\n"
        b"It\\'92s free and open source: github.com/lhaeger/tnef-quicklook\\par\\par\r\n"
        b"Cheers,\\par Alex\\par}\r\n"
    )
    picture_object = compound_file([("\x01Ole", b"\x01\x00\x00\x02" + b"\0" * 16), ("CONTENTS", picture)])
    return tnef(
        attribute(LVL_MESSAGE, ATT_SUBJECT, b"Did you know? Peek inside winmail.dat\0"),
        attribute(
            LVL_MESSAGE,
            ATT_MSG_PROPS,
            mapi_props(
                prop_variable(PT_UNICODE, PR_SENT_REPRESENTING_NAME, unicode_z("Alex Example")),
                prop_variable(PT_UNICODE, PR_SENDER_EMAIL_ADDRESS, unicode_z("alex@example.com")),
                prop_systime(PR_CLIENT_SUBMIT_TIME, 2026, 11, 9, 9, 41),
                prop_variable(PT_BINARY, PR_RTF_COMPRESSED, compress_rtf(rtf)),
            ),
        ),
        ole_attachment("Untitled Attachment", picture_object, position=180),
        file_attachment("RELEAS~1.PDF", "Release notes.pdf", "application/pdf", tiny_pdf("TNEF Preview release notes")),
        file_attachment("INSTAL~1.TXT", "Install checklist.txt", "text/plain",
                        b"1. Run scripts/install.sh\n2. Press the space bar on a winmail.dat\n"),
    )


def main() -> int:
    if len(sys.argv) == 4 and sys.argv[1] == "--demo":
        picture = Path(sys.argv[2]).read_bytes()
        Path(sys.argv[3]).write_bytes(demo(picture))
        print(f"wrote {sys.argv[3]}")
        return 0
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    for name, build in (("basic.dat", basic), ("html.dat", html), ("rtf-only.dat", rtf_only), ("ole.dat", ole)):
        (out / name).write_bytes(build())
        print(f"wrote {out / name}")
    (out / "rtf-body.rtf").write_bytes(RTF_BODY)
    return 0


if __name__ == "__main__":
    sys.exit(main())
