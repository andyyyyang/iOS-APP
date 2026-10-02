import UIKit

enum ImagePreprocessor {
    /// 將圖片轉正為 `.up` 方向，並把長邊限制在 `maxPixelLength` 以內。
    /// 轉正後 Vision 回傳的座標可以直接對應到顯示的圖片。
    static func normalized(_ image: UIImage, maxPixelLength: CGFloat = 4096) -> UIImage {
        let pixelSize = CGSize(width: image.size.width * image.scale, height: image.size.height * image.scale)
        let longest = max(pixelSize.width, pixelSize.height)
        guard longest > 0 else { return image }

        let ratio = min(1, maxPixelLength / longest)
        if image.imageOrientation == .up, ratio == 1, image.cgImage != nil {
            return image
        }

        let target = CGSize(
            width: max(1, (pixelSize.width * ratio).rounded()),
            height: max(1, (pixelSize.height * ratio).rounded())
        )
        return render(image, size: target)
    }

    static func thumbnailJPEGData(_ image: UIImage, maxPixelLength: CGFloat = 480) -> Data? {
        normalized(image, maxPixelLength: maxPixelLength).jpegData(compressionQuality: 0.7)
    }

    private static func render(_ image: UIImage, size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
