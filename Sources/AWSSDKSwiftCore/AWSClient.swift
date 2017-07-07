//
//  Client.swift
//  AWSSDKSwift
//
//  Created by Yuki Takei on 2017/03/13.
//
//

import Foundation
import Dispatch
import Prorsum
import HypertextApplicationLanguage

extension Characters {
    public static let uriAWSQueryAllowed: Characters = ["!", "$", "&", "\'", "(", ")", "+", "-", ".", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "=", "?", "@", "A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z", "_", "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z"
    ]
}

extension Prorsum.Body {
    func asData() -> Data {
        switch self {
        case .buffer(let data):
            return data
        default:
            return Data()
        }
    }
}

public struct InputContext {
    let Shape: AWSShape.Type
    let input: AWSShape
}

public struct AWSClient {
    let signer: Signers.V4
    
    let apiVersion: String
    
    let amzTarget: String?
    
    let _endpoint: String?
    
    let serviceProtocol: ServiceProtocol
    
    private var cond = Cond()
    
    let serviceEndpoints: [String: String]
    
    let partitionEndpoint: String?
    
    public let middlewares: [AWSRequestMiddleware]
    
    public var possibleErrorTypes: [AWSErrorType.Type]
    
    public var endpoint: String {
        if let givenEndpoint = self._endpoint {
            return givenEndpoint
        }
        return "https://\(serviceHost)"
    }
    
    public var serviceHost: String {
        if let serviceEndpoint = serviceEndpoints[signer.region.rawValue] {
            return serviceEndpoint
        }
        
        if let partitionEndpoint = partitionEndpoint, let globalEndpoint = serviceEndpoints[partitionEndpoint] {
            return globalEndpoint
        }
        return "\(signer.service).\(signer.region.rawValue).amazonaws.com"
    }
    
    public init(accessKeyId: String? = nil, secretAccessKey: String? = nil, region givenRegion: Region?, amzTarget: String? = nil, service: String, serviceProtocol: ServiceProtocol, apiVersion: String, endpoint: String? = nil, serviceEndpoints: [String: String] = [:], partitionEndpoint: String? = nil, middlewares: [AWSRequestMiddleware] = [], possibleErrorTypes: [AWSErrorType.Type]? = nil) {
        let cred: CredentialProvider
        if let scred = SharedCredential.default {
            cred = scred
        } else {
            if let accessKey = accessKeyId, let secretKey = secretAccessKey {
                cred = Credential(accessKeyId: accessKey, secretAccessKey: secretKey)
            } else if let ecred = EnvironementCredential() {
                cred = ecred
            } else {
                cred = Credential(accessKeyId: "", secretAccessKey: "")
            }
        }
        
        let region: Region
        if let _region = givenRegion {
            region = _region
        }
        else if let partitionEndpoint = partitionEndpoint, let reg = Region(rawValue: partitionEndpoint) {
            region = reg
        } else if let defaultRegion = ProcessInfo.processInfo.environment["AWS_DEFAULT_REGION"], let reg = Region(rawValue: defaultRegion) {
            region = reg
        } else {
            region = .useast1
        }
        
        self.signer = Signers.V4(credentials: cred, region: region, service: service)
        self.apiVersion = apiVersion
        self._endpoint = endpoint
        self.amzTarget = amzTarget
        self.serviceProtocol = serviceProtocol
        self.serviceEndpoints = serviceEndpoints
        self.partitionEndpoint = partitionEndpoint
        self.middlewares = middlewares
        self.possibleErrorTypes = possibleErrorTypes ?? []
    }
}

// invoker
extension AWSClient {
    fileprivate func invoke(request: Request) throws -> Response {
        // TODO implement Keep-alive
        let client = try HTTPClient(url: request.url)
        try client.open()
        let response = try client.request(request)
        client.close()
        
        return response
    }
}

// public facing apis
extension AWSClient {
    public func send<Input: AWSShape>(operation operationName: String, path: String, httpMethod: String, input: Input) throws {
        let request = try createRequest(
            operation: operationName,
            path: path,
            httpMethod:
            httpMethod,
            context: InputContext(Shape: Input.self, input: input)
        )
        
        _ = try self.request(request)
    }
    
    public func send(operation operationName: String, path: String, httpMethod: String) throws {
        let request = try createRequest(operation: operationName, path: path, httpMethod: httpMethod)
        _ = try self.request(request)
    }
    
    public func send<Output: AWSShape>(operation operationName: String, path: String, httpMethod: String) throws -> Output {
        let request = try createRequest(operation: operationName, path: path, httpMethod: httpMethod)
        return try validate(operation: operationName, response: try self.request(request))
    }
    
    public func send<Output: AWSShape, Input: AWSShape>(operation operationName: String, path: String, httpMethod: String, input: Input)
        throws -> Output {
            
        let request = try createRequest(
            operation: operationName,
            path: path,
            httpMethod: httpMethod,
            context: InputContext(Shape: Input.self, input: input)
        )
        return try validate(operation: operationName, response: try self.request(request))
    }
}

// request creator
extension AWSClient {
    func createProrsumRequestWithSignedURL(_ request: AWSRequest) throws -> Request {
        var prorsumRequest = try request.toProrsumRequest()
        prorsumRequest.url = signer.signedURL(url: prorsumRequest.url)
        prorsumRequest.headers["Host"] = prorsumRequest.url.hostWithPort!
        return prorsumRequest
    }
    
    func createProrsumRequestWithSignedHeader(_ request: AWSRequest) throws -> Request {
        return try prorsumRequestWithSignedHeader(request.toProrsumRequest())
    }
    
    func prorsumRequestWithSignedHeader(_ prorsumRequest: Request) throws -> Request {
        var prorsumRequest = prorsumRequest
        // TODO avoid copying
        var headers: [String: String] = [:]
        for (key, value) in prorsumRequest.headers {
            headers[key.description] = value
        }
        
        let signedHeaders = signer.signedHeaders(
            url: prorsumRequest.url,
            headers: headers,
            method: prorsumRequest.method.rawValue,
            bodyData: prorsumRequest.body.asData()
        )
        
        for (key, value) in signedHeaders {
            prorsumRequest.headers[key] = value
        }
        
        return prorsumRequest
    }
    
    func request(_ request: AWSRequest) throws -> Prorsum.Response {
        let prorsumRequest: Request
        switch request.httpMethod {
        case "GET":
            switch serviceProtocol.type {
            case .restjson:
                prorsumRequest = try createProrsumRequestWithSignedHeader(request)
                
            default:
                prorsumRequest = try createProrsumRequestWithSignedURL(request)
            }
        default:
            prorsumRequest = try createProrsumRequestWithSignedHeader(request)
        }
        
        return try invoke(request: prorsumRequest)
    }
    
    fileprivate func createRequest(operation operationName: String, path: String, httpMethod: String, context: InputContext? = nil) throws -> AWSRequest {
        var headers: [String: String] = [:]
        var body: Body = .empty
        var path = path
        var queryParams = [URLQueryItem]()
        
        if let ctx = context {
            let mirror = Mirror(reflecting: ctx.input)
            
            for (key, value) in ctx.Shape.headerParams {
                if let attr = mirror.getAttribute(forKey: value.toSwiftVariableCase()) {
                    headers[key] = "\(attr)"
                }
            }
            
            for (key, value) in ctx.Shape.queryParams {
                if let attr = mirror.getAttribute(forKey: value.toSwiftVariableCase()) {
                    queryParams.append(URLQueryItem(name: key, value: "\(attr)"))
                }
            }
            
            for (key, value) in ctx.Shape.pathParams {
                if let attr = mirror.getAttribute(forKey: value.toSwiftVariableCase()) {
                    path = path.replacingOccurrences(of: "{\(key)}", with: "\(attr)").replacingOccurrences(of: "{\(key)+}", with: "\(attr)")
                }
            }
            
            if !queryParams.isEmpty {
                let separator = path.contains("?") ? "&" : "?"
                path = path+separator+queryParams.asStringForURL
            }
            
            switch serviceProtocol.type {
            case .json, .restjson:
                if let payload = ctx.Shape.payload, let payloadBody = mirror.getAttribute(forKey: payload.toSwiftVariableCase()) {
                    body = Body(anyValue: payloadBody)
                    headers.removeValue(forKey: payload.toSwiftVariableCase())
                } else {
                    body = .json(try ctx.input.serializeToDictionary())
                }
                
            case .query:
                var dict = try ctx.input.serializeToDictionary()
                dict["Action"] = operationName
                dict["Version"] = apiVersion
                
                var queryItems = [String]()
                let keys = Array(dict.keys).sorted {$0.localizedCompare($1) == ComparisonResult.orderedAscending }
                
                for key in keys {
                    if let value = dict[key] {
                        queryItems.append("\(key)=\(value)")
                    }
                }
                
                let params = queryItems.joined(separator: "&").percentEncoded(allowing: Characters.uriAWSQueryAllowed)
                
                if path.contains("?") {
                    path += "&" + params
                } else {
                    path += "?" + params
                }
                
                body = .text(params)
                
            case .restxml:
                if let payload = ctx.Shape.payload, let payloadBody = mirror.getAttribute(forKey: payload.toSwiftVariableCase()) {
                    body = Body(anyValue: payloadBody)
                    headers.removeValue(forKey: payload.toSwiftVariableCase())
                } else {
                    body = .xml(try ctx.input.serializeToXMLNode())
                }
                
            case .other(let proto):
                switch proto.lowercased() {
                case "ec2":
                    var params = try ctx.input.serializeToDictionary()
                    params["Action"] = operationName
                    params["Version"] = apiVersion
                    body = .text(params.map({ "\($0.key)=\($0.value)" }).joined(separator: "&"))
                default:
                    break
                }
            }
        }
        
        return AWSRequest(
            region: self.signer.region,
            url: URL(string:  "\(endpoint)\(path)")!,
            serviceProtocol: serviceProtocol,
            service: signer.service,
            amzTarget: amzTarget,
            operation: operationName,
            httpMethod: httpMethod,
            httpHeaders: headers,
            body: body,
            middlewares: middlewares
        )
    }
}

// response validator
extension AWSClient {
    // TODO Rafactor me. too long method
    fileprivate func validate<Output: AWSShape>(operation operationName: String, response: Prorsum.Response) throws -> Output {
        var responseBody: Body = .empty
        let data = response.body.asData()
        
        if !data.isEmpty {
            switch serviceProtocol.type {
            case .json, .restjson:
                if let cType = response.contentType, cType.subtype.contains("hal+json") {
                    let representation = try Representation.from(json: data)
                    var dictionary = representation.properties
                    for rel in representation.rels {
                        guard let representations = try Representation.from(json: data).representations(for: rel) else {
                            continue
                        }
                        
                        guard let hint = Output.parsingHints.filter({ $0.location?.name == rel }).first else {
                            continue
                        }
                        
                        switch hint.type {
                        case .list:
                            let properties : [[String: Any]] = try representations.map({
                                var props = $0.properties
                                var linkMap: [String: [Link]] = [:]
                                
                                for link in $0.links {
                                    let key = link.rel.camelCased(separator: ":")
                                    if linkMap[key] == nil {
                                        linkMap[key] = []
                                    }
                                    linkMap[key]?.append(link)
                                }
                                
                                for (key, links) in linkMap {
                                    var dict: [String: Any] = [:]
                                    for link in links {
                                        guard let name = link.name else { continue }
                                        guard let url = URL(string: endpoint+link.href) else { continue }
                                        let res = try invoke(request: prorsumRequestWithSignedHeader(Request(method: .get, url: url)))
                                        let representaion = try Representation().from(json: res.body.asData())
                                        dict[name] = representaion.properties
                                    }
                                    props[key] = dict
                                }
                                
                                return props
                            })
                            dictionary[rel] = properties
                            
                        default:
                            dictionary[rel] = representations.map({ $0.properties }).first ?? [:]
                        }
                    }
                    responseBody = .json(dictionary)
                    
                } else {
                    if let dictionary = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any] {
                        responseBody = .json(dictionary)
                    }
                }
                
            case .restxml, .query:
                let xmlNode = try XML2Parser(data: data).parse()
                responseBody = .xml(xmlNode)
                
            case .other(let proto):
                switch proto.lowercased() {
                case "ec2":
                    let xmlNode = try XML2Parser(data: data).parse()
                    responseBody = .xml(xmlNode)
                    
                default:
                    responseBody = .buffer(data)
                }
            }
        }
        
        var responseHeaders: [String: String] = [:]
        for (key, value) in response.headers {
            responseHeaders[key.description] = value
        }
        
        guard (200..<300).contains(response.statusCode) else {
            var bodyDict = try responseBody.asDictionary() ?? [:]
            var code: String?
            var message: String?
            
            switch serviceProtocol.type {
            case .query:
                guard let dict = bodyDict["ErrorResponse"] as? [String: Any] else {
                    break
                }
                let errorDict = dict["Error"] as? [String: Any]
                code = errorDict?["Code"] as? String
                message = errorDict?["Message"] as? String
                
            case .restxml:
                let errorDict = bodyDict["Error"] as? [String: Any]
                code = errorDict?["Code"] as? String
                message = errorDict?["Message"] as? String
                
            case .restjson:
                code = response.headers["x-amzn-ErrorType"]
                message = bodyDict.filter({ $0.key.lowercased() == "message" }).first?.value as? String
                
            case .json:
                code = bodyDict["__type"] as? String
                message = bodyDict.filter({ $0.key.lowercased() == "message" }).first?.value as? String
                
            default:
                break
            }
            
            if let errorCode = code {
                for errorType in possibleErrorTypes {
                    if let error = errorType.init(errorCode: errorCode, message: message) {
                        throw error
                    }
                }
                
                if let error = AWSClientError(errorCode: errorCode, message: message) {
                    throw error
                }
                
                if let error = AWSServerError(errorCode: errorCode, message: message) {
                    throw error
                }
                
                throw AWSResponseError(errorCode: errorCode, message: message)
            }
            
            throw AWSError(message: message ?? "Unhandled Error", rawBody: String(data: data, encoding: .utf8) ?? "")
        }
        
        var outputDict: [String: Any] = [:]
        switch responseBody {
        case .json(let dictionary):
            outputDict = dictionary
            outputDict["StatusCode"] = Int32(response.statusCode)
            
        case .xml(let node):
            let str = XMLNodeSerializer(node: node).serializeToJSON()
            outputDict = try JSONSerialization.jsonObject(with: str.data(using: .utf8)!, options: []) as? [String: Any] ?? [:]
            
            if let childOutputDict = outputDict[operationName+"Response"] as? [String: Any] {
                outputDict = childOutputDict
                if let childOutputDict = outputDict[operationName+"Result"] as? [String: Any] {
                    outputDict = childOutputDict
                }
            } else {
                if let key = outputDict.keys.first, let dict = outputDict[key] as? [String: Any] {
                    outputDict = dict
                }
            }
            
        case .buffer(let data):
            if let payload = Output.payload {
                outputDict[payload] = data
            }
            
        case .text(let text):
            if let payload = Output.payload {
                outputDict[payload] = text
            }
            
        default:
            break
        }
        
        for (key, value) in response.headers {
            if let param = Output.headerParams.filter({ $0.key.lowercased() == key.description.lowercased() }).first {
                outputDict[param.key] = value
            }
        }
        
        return try Output(dictionary: outputDict)
    }
}
