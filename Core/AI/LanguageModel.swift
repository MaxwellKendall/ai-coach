import FoundationModels

enum LanguageModel {
    /// Voice and natural-language entry are hidden when this is false; manual flows always work.
    static var isAvailable: Bool { OnDeviceModel().isAvailable }
}
