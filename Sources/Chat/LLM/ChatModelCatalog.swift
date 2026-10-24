import Foundation

/// Модель для чата. На стенде MLX (12.10.2026) осталась одна: Qwen3 4B.
/// Лёгкая Qwen3.5 2B дала 59 % точности плана и зацикливалась, поэтому её нет.
/// Ревизия закреплена хэшем коммита: только так клиент Hugging Face берёт уже
/// скачанную модель из кэша, не выходя в сеть (с `main` он каждый раз
/// запрашивает список файлов). Размер — из API Hugging Face, память — замер
/// стенда на M4: около 2,16 ГБ в работе и 2,83 ГБ на пике
enum ChatModelChoice: String, CaseIterable, Codable, Identifiable, Sendable {
    case standard

    var id: String { rawValue }

    var repository: String { "mlx-community/Qwen3-4B-Instruct-2507-4bit" }

    var revision: String { "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b" }

    /// Сколько байт скачивается: веса, токенизатор, шаблон чата
    var downloadBytes: Int64 { 2_278_969_697 }

    /// Сколько свободной памяти нужно приложению перед загрузкой: пик стенда
    /// плюс запас на сам чат. Повышенный лимит памяти не запрошен — он мешал
    /// бы подписи IPA присланным профилем (см. IPA_RELEASE.md)
    var requiredMemoryBytes: Int64 { 3_000_000_000 }

    var modelName: String { "Qwen3 4B" }

    /// Только то, что нужно для ответа: веса, конфигурация, токенизатор и
    /// его словари, шаблон чата
    static let filePatterns = ["*.safetensors", "*.json", "*.jinja", "*.txt"]
}
