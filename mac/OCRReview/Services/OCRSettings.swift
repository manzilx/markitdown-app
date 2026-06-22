import Foundation

enum OCRSettings {
    static let engineKey = "ocrreview.engine"
    static let sidecarURLKey = "ocrreview.sidecar_url"

    static var selectedEngine: String {
        get { UserDefaults.standard.string(forKey: engineKey) ?? "vision" }
        set { UserDefaults.standard.set(newValue, forKey: engineKey) }
    }

    static var sidecarURL: String {
        get {
            UserDefaults.standard.string(forKey: sidecarURLKey) ?? SidecarConfig.defaultBaseURL
        }
        set { UserDefaults.standard.set(newValue, forKey: sidecarURLKey) }
    }

    static let projectRootKey = "ocrreview.project_root"

    static var projectRootPath: String? {
        get { UserDefaults.standard.string(forKey: projectRootKey) }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue, forKey: projectRootKey)
            } else {
                UserDefaults.standard.removeObject(forKey: projectRootKey)
            }
        }
    }

    static var usesSidecarOCR: Bool {
        selectedEngine != "vision"
    }

    static func supportsSidecarPageOCR(_ engineID: String) -> Bool {
        switch engineID {
        case "vision", "builtin", "pymupdf4llm":
            return false
        default:
            return true
        }
    }

    static func engineLabel(for engineID: String) -> String {
        switch engineID {
        case "vision": "Apple Vision · on-device"
        case "builtin": "Built-in · converter only"
        case "azure_doc_intel": "Azure Doc Intelligence"
        case "pymupdf4llm": "PyMuPDF4LLM · converter only"
        case "ocr_plugin": "LLM OCR"
        default: engineID
        }
    }
}
