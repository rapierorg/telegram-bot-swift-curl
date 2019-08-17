import Foundation
import CCurl
import TelegramBotSDKRequestProvider

class CurlRequestProvider: RequestProvider {
    static func doRequest(endpointUrl: URL, contentType: String, requestData: Data, completion: @escaping RequestCompletion) {
        var completeRequestData = requestData
        completeRequestData.append(0)
        
        // -1 for '\0'
        let byteCount = requestData.count - 1
        completeRequestData.withUnsafeBytes { (bytes) -> Void in
            curlPerformRequest(endpointUrl: endpointUrl, contentType: contentType, requestBytes: bytes, byteCount: byteCount, completion: completion)
        }
    }
    
    /// Note: performed on global queue
    static private func curlPerformRequest(endpointUrl: URL, contentType: String, requestBytes: UnsafePointer<UInt8>, byteCount: Int, completion: @escaping RequestCompletion) {
        var callbackData = WriteCallbackData()
        
        guard let curl = curl_easy_init() else {
            completion(Data(), .wrapperError(code: 0, message: "Lib Curl init error"))
            return
        }
        defer { curl_easy_cleanup(curl) }
        
        curl_easy_setopt_string(curl, CURLOPT_URL, endpointUrl.absoluteString)
        //curl_easy_setopt_int(curl, CURLOPT_SAFE_UPLOAD, 1)
        curl_easy_setopt_int(curl, CURLOPT_POST, 1)
        curl_easy_setopt_binary(curl, CURLOPT_POSTFIELDS, requestBytes)
        curl_easy_setopt_int(curl, CURLOPT_POSTFIELDSIZE, Int32(byteCount))
        
        var headers: UnsafeMutablePointer<curl_slist>? = nil
        headers = curl_slist_append(headers, "Content-Type: \(contentType)")
        curl_easy_setopt_slist(curl, CURLOPT_HTTPHEADER, headers)
        defer { curl_slist_free_all(headers) }
        
        let writeFunction: curl_write_callback = { (ptr, size, nmemb, userdata) -> Int in
            let count = size * nmemb
            if let writeCallbackDataPointer = userdata?.assumingMemoryBound(to: WriteCallbackData.self) {
                let writeCallbackData = writeCallbackDataPointer.pointee
                ptr?.withMemoryRebound(to: UInt8.self, capacity: count) {
                    writeCallbackData.data.append(&$0.pointee, count: count)
                }
            }
            return count
        }
        curl_easy_setopt_write_function(curl, CURLOPT_WRITEFUNCTION, writeFunction)
        curl_easy_setopt_pointer(curl, CURLOPT_WRITEDATA, &callbackData)
        //curl_easy_setopt_int(curl, CURLOPT_VERBOSE, 1)
        let code = curl_easy_perform(curl)
        guard code == CURLE_OK else {
            reportCurlError(code: code, completion: completion)
            return
        }
        
        //let result = String(data: callbackData.data, encoding: .utf8)
        //print("CURLcode=\(code.rawValue) result=\(result.unwrapOptional)")
        
        guard code != CURLE_ABORTED_BY_CALLBACK else {
            completion(Data(), .wrapperError(code: Int(CURLE_ABORTED_BY_CALLBACK.rawValue), message: "Curl aborted by callback"))
            return
        }
        
        let data = callbackData.data
        
        var httpCode: Int = 0
        guard CURLE_OK == curl_easy_getinfo_long(curl, CURLINFO_RESPONSE_CODE, &httpCode) else {
            reportCurlError(code: code, completion: completion)
            return
        }
        
        guard httpCode == 200 else {
            completion(nil, .invalidStatusCode(statusCode: httpCode, data: data))
            return
        }
        
        guard !data.isEmpty else {
            completion(nil, .noDataReceived)
            return
            
        }
        
        completion(data, nil)
    }
    
    private static func reportCurlError(code: CURLcode, completion: @escaping (_ data: Data, _ error: RequestError?)->()) {
        let failReason = String(cString: curl_easy_strerror(code), encoding: .utf8) ?? "unknown error"
        //print("Request failed: \(failReason)")
        completion(Data(), .wrapperError(code: Int(code.rawValue), message: failReason))
    }
}
