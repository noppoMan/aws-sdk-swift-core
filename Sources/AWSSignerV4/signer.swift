//
//  signer.swift
//  AWSSigner
//
//  Created by Adam Fowler on 2019/08/29.
//  Amazon Web Services V4 Signer
//  AWS documentation about signing requests is here https://docs.aws.amazon.com/general/latest/gr/signing_aws_api_requests.html
//

import struct Foundation.CharacterSet
import struct Foundation.Data
import struct Foundation.Date
import class Foundation.DateFormatter
import struct Foundation.Locale
import struct Foundation.TimeZone
import struct Foundation.URL
import AWSCrypto
import NIO
import NIOHTTP1

/// Amazon Web Services V4 Signer
public struct AWSSigner {
    /// security credentials for accessing AWS services
    public let credentials: Credential
    /// service signing name. In general this is the same as the service name
    public let name: String
    /// AWS region you are working in
    public let region: String

    static let hashedEmptyBody = SHA256.hash(data: [UInt8]()).hexDigest()

    static private let timeStampDateFormatter: DateFormatter = createTimeStampDateFormatter()

    /// Initialise the Signer class with AWS credentials
    public init(credentials: Credential, name: String, region: String) {
        self.credentials = credentials
        self.name = name
        self.region = region
    }

    /// Enum for holding your body data
    public enum BodyData {
        case string(String)
        case data(Data)
        case byteBuffer(ByteBuffer)
    }

    /// Generate signed headers, for a HTTP request
    public func signHeaders(url: URL, method: HTTPMethod = .GET, headers: HTTPHeaders = HTTPHeaders(), body: BodyData? = nil, date: Date = Date()) -> HTTPHeaders {
        let bodyHash = AWSSigner.hashedPayload(body)
        let dateString = AWSSigner.timestamp(date)
        var headers = headers
        // add date, host, sha256 and if available security token headers
        headers.add(name: "X-Amz-Date", value: dateString)
        headers.add(name: "host", value: url.host ?? "")
        headers.add(name: "x-amz-content-sha256", value: bodyHash)
        if let sessionToken = credentials.sessionToken {
            headers.add(name: "x-amz-security-token", value: sessionToken)
        }

        // construct signing data. Do this after adding the headers as it uses data from the headers
        let signingData = AWSSigner.SigningData(url: url, method: method, headers: headers, body: body, bodyHash: bodyHash, date: dateString, signer: self)

        // construct authorization string
        let authorization = "AWS4-HMAC-SHA256 " +
            "Credential=\(credentials.accessKeyId)/\(signingData.date)/\(region)/\(name)/aws4_request, " +
            "SignedHeaders=\(signingData.signedHeaders), " +
        "Signature=\(signature(signingData: signingData))"

        // add Authorization header
        headers.add(name: "Authorization", value: authorization)

        return headers
    }

    /// Generate a signed URL, for a HTTP request
    public func signURL(url: URL, method: HTTPMethod = .GET, body: BodyData? = nil, date: Date = Date(), expires: Int = 86400) -> URL {
        let headers = HTTPHeaders([("host", url.host ?? "")])
        // Create signing data
        var signingData = AWSSigner.SigningData(url: url, method: method, headers: headers, body: body, date: AWSSigner.timestamp(date), signer: self)
        // Construct query string. Start with original query strings and append all the signing info.
        var query = url.query ?? ""
        if query.count > 0 {
            query += "&"
        }
        query += "X-Amz-Algorithm=AWS4-HMAC-SHA256"
        query += "&X-Amz-Credential=\(credentials.accessKeyId)/\(signingData.date)/\(region)/\(name)/aws4_request"
        query += "&X-Amz-Date=\(signingData.datetime)"
        query += "&X-Amz-Expires=\(expires)"
        query += "&X-Amz-SignedHeaders=\(signingData.signedHeaders)"
        if let sessionToken = credentials.sessionToken {
            query += "&X-Amz-Security-Token=\(sessionToken.uriEncode())"
        }
        // Split the string and sort to ensure the order of query strings is the same as AWS
        query = query.split(separator: "&")
            .sorted()
            .joined(separator: "&")
            .queryEncode()

        // update unsignedURL in the signingData so when the canonical request is constructed it includes all the signing query items
        signingData.unsignedURL = URL(string: url.absoluteString.split(separator: "?")[0]+"?"+query)! // NEED TO DEAL WITH SITUATION WHERE THIS FAILS
        query += "&X-Amz-Signature=\(signature(signingData: signingData))"

        // Add signature to query items and build a new Request
        let signedURL = URL(string: url.absoluteString.split(separator: "?")[0]+"?"+query)!

        return signedURL
    }

    /// structure used to store data used throughout the signing process
    struct SigningData {
        let url : URL
        let method : HTTPMethod
        let hashedPayload : String
        let datetime : String
        let headersToSign: [String: String]
        let signedHeaders : String
        var unsignedURL : URL

        var date : String { return String(datetime.prefix(8))}

        init(url: URL, method: HTTPMethod = .GET, headers: HTTPHeaders = HTTPHeaders(), body: BodyData? = nil, bodyHash: String? = nil, date: String, signer: AWSSigner) {
            self.url = url
            self.method = method
            self.datetime = date
            self.unsignedURL = self.url

            if let hash = bodyHash {
                self.hashedPayload = hash
            } else if signer.name == "s3" {
                self.hashedPayload = "UNSIGNED-PAYLOAD"
            } else {
                self.hashedPayload = AWSSigner.hashedPayload(body)
            }

            let headersNotToSign: Set<String> = [
                "Authorization"
            ]
            var headersToSign: [String: String] = [:]
            var signedHeadersArray: [String] = []
            for header in headers {
                if headersNotToSign.contains(header.name) {
                    continue
                }
                headersToSign[header.name] = header.value
                signedHeadersArray.append(header.name.lowercased())
            }
            self.headersToSign = headersToSign
            self.signedHeaders = signedHeadersArray.sorted().joined(separator: ";")
        }
    }

    // Stage 3 Calculating signature as in https://docs.aws.amazon.com/general/latest/gr/sigv4-calculate-signature.html
    func signature(signingData: SigningData) -> String {
        let kDate = HMAC<SHA256>.authenticationCode(for: [UInt8](signingData.date.utf8), using: SymmetricKey(data: Array("AWS4\(credentials.secretAccessKey)".utf8)))
        let kRegion = HMAC<SHA256>.authenticationCode(for: [UInt8](region.utf8), using: SymmetricKey(data: kDate))
        let kService = HMAC<SHA256>.authenticationCode(for: [UInt8](name.utf8), using: SymmetricKey(data: kRegion))
        let kSigning = HMAC<SHA256>.authenticationCode(for: [UInt8]("aws4_request".utf8), using: SymmetricKey(data: kService))
        let kSignature = HMAC<SHA256>.authenticationCode(for: [UInt8](stringToSign(signingData: signingData).utf8), using: SymmetricKey(data: kSigning))
        return kSignature.hexDigest()
    }

    /// Stage 2 Create the string to sign as in https://docs.aws.amazon.com/general/latest/gr/sigv4-create-string-to-sign.html
    func stringToSign(signingData: SigningData) -> String {
        let stringToSign = "AWS4-HMAC-SHA256\n" +
            "\(signingData.datetime)\n" +
            "\(signingData.date)/\(region)/\(name)/aws4_request\n" +
            SHA256.hash(data: [UInt8](canonicalRequest(signingData: signingData).utf8)).hexDigest()
        return stringToSign
    }

    /// Stage 1 Create the canonical request as in https://docs.aws.amazon.com/general/latest/gr/sigv4-create-canonical-request.html
    func canonicalRequest(signingData: SigningData) -> String {
        let canonicalHeaders = signingData.headersToSign.map { return "\($0.key.lowercased()):\($0.value.trimmingCharacters(in: CharacterSet.whitespaces))" }
            .sorted()
            .joined(separator: "\n")
        let canonicalRequest = "\(signingData.method.rawValue)\n" +
            "\(signingData.unsignedURL.path.uriEncodeWithSlash())\n" +
            "\(signingData.unsignedURL.query ?? "")\n" +        // should really uriEncode all the query string values
            "\(canonicalHeaders)\n\n" +
            "\(signingData.signedHeaders)\n" +
            signingData.hashedPayload
        return canonicalRequest
    }

    /// Create a SHA256 hash of the Requests body
    static func hashedPayload(_ payload: BodyData?) -> String {
        guard let payload = payload else { return hashedEmptyBody }
        let hash : String?
        switch payload {
        case .string(let string):
            hash = SHA256.hash(data: [UInt8](string.utf8)).hexDigest()
        case .data(let data):
            hash = SHA256.hash(data: data).hexDigest()
        case .byteBuffer(let byteBuffer):
            let byteBufferView = byteBuffer.readableBytesView
            hash = byteBufferView.withContiguousStorageIfAvailable { bytes in
                return SHA256.hash(data: bytes).hexDigest()
            }
        }
        if let hash = hash {
            return hash
        } else {
            return hashedEmptyBody
        }
    }

    /// return a hexEncoded string buffer from an array of bytes
    static func hexEncoded(_ buffer: [UInt8]) -> String {
        return buffer.map{String(format: "%02x", $0)}.joined(separator: "")
    }
    /// create timestamp dateformatter
    static private func createTimeStampDateFormatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        formatter.timeZone = TimeZone(abbreviation: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }

    /// return a timestamp formatted for signing requests
    static func timestamp(_ date: Date) -> String {
        return timeStampDateFormatter.string(from: date)
    }
}

extension String {
    func queryEncode() -> String {
        return addingPercentEncoding(withAllowedCharacters: String.queryAllowedCharacters) ?? self
    }

    func uriEncode() -> String {
        return addingPercentEncoding(withAllowedCharacters: String.uriAllowedCharacters) ?? self
    }

    func uriEncodeWithSlash() -> String {
        return addingPercentEncoding(withAllowedCharacters: String.uriAllowedWithSlashCharacters) ?? self
    }

    static let uriAllowedWithSlashCharacters = CharacterSet(charactersIn:"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/")
    static let uriAllowedCharacters = CharacterSet(charactersIn:"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
    static let queryAllowedCharacters = CharacterSet(charactersIn:"/;+").inverted
}

public extension Sequence where Element == UInt8 {
    /// return a hexEncoded string buffer from an array of bytes
    func hexDigest() -> String {
        return self.map{String(format: "%02x", $0)}.joined(separator: "")
    }
}
