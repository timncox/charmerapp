import Foundation

enum BlobUploader {

    struct UploadResult {
        let url: String
        let filename: String
    }

    static func upload(filePath: String, filename: String) -> UploadResult? {
        let isVideo = filename.lowercased().hasSuffix(".mp4")
        let contentType = isVideo ? "video/mp4" : "image/jpeg"

        let urlString = "\(Config.blobUploadBase)/charmera/\(filename)"
        guard let url = URL(string: urlString) else {
            print("[BlobUploader] Invalid URL: \(urlString)")
            return nil
        }

        guard let fileData = FileManager.default.contents(atPath: filePath) else {
            print("[BlobUploader] Cannot read file: \(filePath)")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(Config.blobToken)", forHTTPHeaderField: "Authorization")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "x-api-blob-no-suffix")
        request.httpBody = fileData

        let semaphore = DispatchSemaphore(value: 0)
        var result: UploadResult?

        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { semaphore.signal() }

            if let error = error {
                print("[BlobUploader] Upload error: \(error.localizedDescription)")
                return
            }

            guard let data = data else {
                print("[BlobUploader] No response data")
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let blobURL = json["url"] as? String {
                    result = UploadResult(url: blobURL, filename: filename)
                } else {
                    let responseStr = String(data: data, encoding: .utf8) ?? "unknown"
                    print("[BlobUploader] Unexpected response: \(responseStr)")
                }
            } catch {
                print("[BlobUploader] JSON parse error: \(error)")
            }
        }
        task.resume()
        semaphore.wait()

        return result
    }
}
