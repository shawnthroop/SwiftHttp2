// Copyright © 2018 Gargoyle Software, LLC
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import Foundation

enum Http2SessionError : Error {
    case readStreamCreateFailed
    case writeStreamCreateFailed
    case outputStreamNotOpen
}

// TODO: https://developer.apple.com/documentation/security/secure_transport
// TODO: https://developer.apple.com/library/content/technotes/tn2232/_index.html

// TODO: https://github.com/nathanborror/swift-http2/blob/master/Sources/Http2.swift
final public class Http2Session : NSObject {
    private static let connectionPreface = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".toUInt8Array()

    private let host: String
    private let port: Int
    private let writeQueue = OperationQueue()

    private let runLoop = RunLoop()

    private var unprocessedBytes: [UInt8] = []
    private var sslContent: SSLContext!

    internal var inputStream: InputStream?
    internal var outputStream: OutputStream?

    private init(host: String, port: Int = 443, streamProperties: [Stream.PropertyKey : Any?]) throws {
        self.host = host
        self.port = port

        Stream.getStreamsToHost(withName: host, port: port, inputStream: &inputStream, outputStream: &outputStream)

        super.init()

        writeQueue.qualityOfService = .userInitiated
        writeQueue.isSuspended = true

        let defaults: [Stream.PropertyKey : Any?] = [
            Stream.PropertyKey(kCFStreamPropertySSLContext as String) : [:],
            .socketSecurityLevelKey : StreamSocketSecurityLevel.negotiatedSSL
        ]

        // Make sure security level is set.  If they sent a value, use theirs instead of ours.
        let properties = streamProperties.merging(defaults) {
            current, _ in
            current
        }

        guard let ctx = inputStream!.property(forKey: Stream.PropertyKey(kCFStreamPropertySSLContext as String)) else {
            fatalError()
        }

        let context = ctx as! SSLContext
        //SSLSetALPNProtocols(context, [] as CFArray)
        SSLSetSessionOption(context, SSLSessionOption.allowRenegotiation, false)
        SSLSetSessionOption(context, SSLSessionOption.breakOnClientAuth, true)
        SSLHandshake(context)

        inputStream!.delegate = self
        properties.forEach {
            print("Setting \($0.key) to \($0.value)")
            if !inputStream!.setProperty($0.value, forKey: $0.key) {
                print("Failed to set \($0.key) to \($0.value)")
            }
        }
        inputStream!.schedule(in: .main, forMode: .defaultRunLoopMode)
        inputStream!.open()

        outputStream!.delegate = self
        outputStream!.schedule(in: .main, forMode: .defaultRunLoopMode)
        outputStream!.open()
    }

    public class func createClient(host: String, port: Int = 443, streamProperties: [Stream.PropertyKey : Any?] = [:]) throws -> Http2Session {
        Http2StreamCache.shared.initialize(as: .client)
        return try Http2Session(host: host, port: port, streamProperties: streamProperties)
    }

    public class func createServer(streamProperties: [Stream.PropertyKey : Any?] = [:]) throws -> Http2Session {
        Http2StreamCache.shared.initialize(as: .server)
        return try Http2Session(host: "", port: 0, streamProperties: streamProperties)
    }

    public func disconnect(sendGoAwayFrame: Bool = true) {
        writeQueue.cancelAllOperations()

        if let inputStream = inputStream {
            inputStream.close()
            inputStream.delegate = nil
            self.inputStream = nil
        }

        if sendGoAwayFrame, let lastStream = Http2StreamCache.shared.orderedStreams().last {
            let goAway = GoAwayFrame(lastStream: lastStream, errorCode: .none)
            _ = try? write(goAway)
            writeQueue.waitUntilAllOperationsAreFinished()
        }

        if let outputStream = outputStream {
            outputStream.close()
            outputStream.delegate = nil
            self.outputStream = nil
        }
    }

    public func write(_ frame: AbstractFrame) throws {
        guard let outputStream = outputStream else {
            throw Http2SessionError.outputStreamNotOpen
        }

        let encoded = try frame.encode()

        writeQueue.addOperation {
            outputStream.write(encoded, maxLength: encoded.count)
        }
    }

    private func read() {
        guard let inputStream = inputStream else { return }

        let length = 4096
        var buffer = [UInt8](repeating: 0, count: length)
        let bytesRead = inputStream.read(&buffer, maxLength: length)

        if bytesRead > 0 {
            unprocessedBytes += buffer[0 ..< bytesRead]

            let frame = try! AbstractFrame.decode(data: unprocessedBytes)
            print(frame)
        } else if bytesRead == 0 {
            disconnect(sendGoAwayFrame: false)
        } else if let error = inputStream.streamError {
            disconnect(sendGoAwayFrame: false)
            print(error)
        }
    }

    // TODO: https://stackoverflow.com/questions/30624738/how-should-secure-transport-tls-be-used-with-bsd-sockets-in-swift/30733961#30733961
    // https://github.com/OpenKitten/Lynx/blob/master/Sources/Lynx/Sockets/TCPSSLClient.swift
    func sslReadFunc(conn: SSLConnectionRef, data: UnsafeMutableRawPointer, dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
        guard let inputStream = inputStream else { return errSecBadReq }

        var buffer = [UInt8](repeating: 0, count: dataLength.pointee)
        let bytesRead = inputStream.read(&buffer, maxLength: dataLength.pointee)

        defer { dataLength.initialize(to: bytesRead) }

        if bytesRead > 0 {
            unprocessedBytes += buffer[0 ..< bytesRead]

            let frame = try! AbstractFrame.decode(data: unprocessedBytes)
            print(frame)
        } else if bytesRead == 0 {
            disconnect(sendGoAwayFrame: false)
            return errSSLClosedGraceful
        } else if let error = inputStream.streamError {
            disconnect(sendGoAwayFrame: false)
            print(error)
        }

        return errSecSuccess
    }

    func sslWriteFunc(conn: SSLConnectionRef, data: UnsafeRawPointer, dataLength: UnsafeMutablePointer<Int>) -> OSStatus {
        return errSecSuccess
    }
}

extension Http2Session :  StreamDelegate {
    public func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        // According to Quinn, we'll never get more than one event at a time.
        // https://forums.developer.apple.com/thread/95632
        if eventCode.isSubset(of: [.endEncountered, .errorOccurred]) {
            disconnect(sendGoAwayFrame: false)
        } else if eventCode.contains(.hasBytesAvailable) {
            guard aStream == inputStream else { return }
            read()
        } else if eventCode.contains(.openCompleted) {
            guard aStream == outputStream else { return }
            print("Sending PRI")
            outputStream!.write(Http2Session.connectionPreface, maxLength: Http2Session.connectionPreface.count)

            writeQueue.isSuspended = false
        }
    }
}
