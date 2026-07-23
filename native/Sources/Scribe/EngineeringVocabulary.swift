import Foundation

/// A curated set of software-engineering terms that Parakeet commonly
/// mis-decodes (proper nouns, tools, protocols), used only to bias the
/// recognizer via `BiasVocabularyBuilder`. Compile-time only — never stored
/// in `UserDictionaryStore` (that would surface fake "learned" terms in the
/// dictionary editor and feed them to the Gemma cleanup prompt).
///
/// Conservative by design: every entry is a genuinely distinctive term whose
/// canonical spelling a general recognizer gets wrong. Entries are ASCII and
/// at least 3 characters (the CTC spotter drops shorter terms). Keep the list
/// tight — an over-broad term biases a common word toward a rare spelling.
enum EngineeringVocabulary {
    static let terms: [String] = [
        // AI / Anthropic
        "Claude", "Anthropic", "OpenAI", "LLM", "GPT",
        // Languages / runtimes
        "Python", "TypeScript", "JavaScript", "Golang", "Rust", "Kotlin",
        "Swift", "Ruby", "Node", "Deno", "WebAssembly",
        // Frameworks / libraries
        "React", "Angular", "Svelte", "Vue", "Rails", "Django", "FastAPI",
        "Next", "Tailwind", "GraphQL",
        // Data stores
        "Postgres", "PostgreSQL", "Redis", "MongoDB", "SQLite", "DynamoDB",
        "Elasticsearch", "Kafka", "RabbitMQ",
        // Infra / DevOps
        "Kubernetes", "Docker", "Terraform", "Ansible", "Nginx", "Helm",
        "Prometheus", "Grafana", "Kamal", "Hetzner", "CloudFlare",
        // Cloud
        "AWS", "GCP", "Azure", "Lambda", "Vercel", "Netlify", "Supabase",
        // Tooling / concepts
        "GitHub", "GitLab", "Kubectl", "Webpack", "ESLint", "Prettier",
        "Xcode", "SwiftUI", "CoreML", "async", "webhook", "OAuth", "JWT",
    ]
}
