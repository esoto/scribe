import Foundation

/// A curated set of software-engineering terms that Parakeet commonly
/// mis-decodes (proper nouns, tools, protocols), used only to bias the
/// recognizer via `BiasVocabularyBuilder`. Compile-time only — never stored
/// in `UserDictionaryStore` (that would surface fake "learned" terms in the
/// dictionary editor and feed them to the Gemma cleanup prompt).
///
/// Conservative by design. Short terms (≤5 chars, acronyms, common-word
/// homophones) are DELIBERATELY EXCLUDED: measured against the fixtures, they
/// were the false-positive engine — "Deno"/"Vue"/"Node"/"Helm"/"Kafka" got
/// swapped in for "bueno"/"que"/"move"/"tell"/ordinary words, especially in
/// Spanish. Only multi-syllable, distinctive terms unlikely to collide with
/// everyday EN/ES vocabulary remain. Keep it tight: every entry is a term a
/// general recognizer mis-decodes AND that no common word sounds like.
enum EngineeringVocabulary {
    static let terms: [String] = [
        // AI
        "Anthropic",
        // Languages / runtimes
        "TypeScript", "JavaScript", "Kotlin", "WebAssembly",
        // Frameworks / libraries
        "Angular", "Svelte", "Django", "FastAPI", "Tailwind", "GraphQL",
        // Data stores
        "Postgres", "PostgreSQL", "MongoDB", "SQLite", "DynamoDB",
        "Elasticsearch", "RabbitMQ",
        // Infra / DevOps
        "Kubernetes", "Docker", "Terraform", "Ansible", "Prometheus",
        "Grafana", "Kamal", "Hetzner", "CloudFlare",
        // Cloud
        "Lambda", "Vercel", "Netlify", "Supabase",
        // Tooling
        "GitHub", "GitLab", "Kubectl", "Webpack", "Prettier",
        "SwiftUI", "CoreML", "webhook",
    ]
}
