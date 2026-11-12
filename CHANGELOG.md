# Changelog

All notable user-facing changes. Versions follow [Semantic Versioning](https://semver.org).
New entries go under **Unreleased**; a release renames that section to the version and date.

## [Unreleased]

### Added
- Native macOS app that starts and stops models on a DGX Spark over SSH and serves them through one
  OpenAI-compatible API at `http://localhost:18080/v1`.
- Built-in chat with image, PDF and text attachments.
- Usage and speed statistics (tokens, cache hit rate, time to first token, prefill/decode speed) over
  4h / 24h / week / month / year / all.
- Per-model Spark ports.
- TensorFold catalog: install TensorFold, download tested models with their drafters, pick context length.
- Benchmarks.
- Release DMGs built by GitHub Actions when a version tag is pushed.
