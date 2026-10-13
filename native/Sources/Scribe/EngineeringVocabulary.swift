import Foundation

/// Compile-time bias terms, never stored in `UserDictionaryStore`. Short terms are excluded:
/// they caused false positives in common EN/ES words.
enum EngineeringVocabulary {
    static let terms: [String] = [
        "Anthropic",
        "TypeScript", "JavaScript", "Kotlin", "WebAssembly",
        "Angular", "Svelte", "Django", "FastAPI", "Tailwind", "GraphQL",
        "Postgres", "PostgreSQL", "MongoDB", "SQLite", "DynamoDB",
        "Elasticsearch", "RabbitMQ",
        "Kubernetes", "Docker", "Terraform", "Ansible", "Prometheus",
        "Grafana", "Kamal", "Hetzner", "CloudFlare",
        "Lambda", "Vercel", "Netlify", "Supabase",
        "GitHub", "GitLab", "Kubectl", "Webpack", "Prettier",
        "SwiftUI", "CoreML", "webhook",
    ]
}
