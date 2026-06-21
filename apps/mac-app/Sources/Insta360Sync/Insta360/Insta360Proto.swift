import Foundation

enum Insta360Proto {
    enum MediaType: Int {
        case video = 0
        case photo = 1
        case videoAndPhoto = 2
    }

    struct GetFileListRequest {
        var mediaType: MediaType = .videoAndPhoto
        var start: UInt32 = 0
        var limit: UInt32 = 500
    }

    struct GetFileListResponse {
        var uris: [String] = []
        var totalCount: UInt32 = 0
    }

    static func encodeGetFileList(_ request: GetFileListRequest) -> Data {
        var data = Data()
        data.appendVarintField(fieldNumber: 1, value: UInt64(request.mediaType.rawValue))
        if request.start > 0 {
            data.appendVarintField(fieldNumber: 2, value: UInt64(request.start))
        }
        data.appendVarintField(fieldNumber: 3, value: UInt64(request.limit))
        return data
    }

    static func decodeGetFileListResponse(_ data: Data) throws -> GetFileListResponse {
        var response = GetFileListResponse()
        var offset = 0
        while offset < data.count {
            let key = try data.readVarint(at: &offset)
            let fieldNumber = Int(key >> 3)
            let wireType = Int(key & 0x7)
            switch (fieldNumber, wireType) {
            case (1, 2):
                let length = Int(try data.readVarint(at: &offset))
                let stringData = data.subdata(in: offset ..< (offset + length))
                offset += length
                if let value = String(data: stringData, encoding: .utf8) {
                    response.uris.append(value)
                }
            case (2, 0):
                response.totalCount = UInt32(try data.readVarint(at: &offset))
            default:
                var mutable = data
                try mutable.skipField(wireType: wireType, offset: &offset)
            }
        }
        return response
    }
}

private extension Data {
    mutating func appendVarintField(fieldNumber: Int, value: UInt64) {
        appendVarint(UInt64((fieldNumber << 3) | 0))
        appendVarint(value)
    }

    mutating func appendVarint(_ value: UInt64) {
        var v = value
        repeat {
            var byte = UInt8(v & 0x7F)
            v >>= 7
            if v != 0 { byte |= 0x80 }
            append(byte)
        } while v != 0
    }

    func readVarint(at offset: inout Int) throws -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while offset < count {
            let byte = self[offset]
            offset += 1
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return result }
            shift += 7
            if shift > 63 { throw ProtoError.invalidVarint }
        }
        throw ProtoError.unexpectedEOF
    }

    mutating func skipField(wireType: Int, offset: inout Int) throws {
        switch wireType {
        case 0:
            _ = try readVarint(at: &offset)
        case 1:
            offset += 8
        case 2:
            let length = Int(try readVarint(at: &offset))
            offset += length
        case 5:
            offset += 4
        default:
            throw ProtoError.unknownWireType
        }
    }
}

enum ProtoError: Error {
    case invalidVarint
    case unexpectedEOF
    case unknownWireType
}
