require "./pdf_audit/version"
require "./pdf_audit/manifest"
require "./pdf_audit/differ"
require "./pdf_audit/linter"
require "./pdf_audit/annotator"

# `pdf-audit` — Visual audit toolkit for PDFs built on
# `aloli-crystal/pdf2text`.
#
# Four pillars :
#   - `PdfAudit::Manifest` : YAML manifest of a PDF (sha256,
#     pages, words with bbox)
#   - `PdfAudit::Differ` : compare two manifests (regression
#     detection)
#   - `PdfAudit::Linter` : detect typographic anomalies (margin
#     overflow, stuck words, orphan punctuation, justify gaps)
#   - `PdfAudit::Annotator` : generate report listing findings
#
# **Quick start :**
#
# ```
# require "pdf_audit"
#
# manifest = PdfAudit::Manifest.from_pdf("doc.pdf")
# findings = PdfAudit::Linter.lint(manifest)
# findings.each do |f|
#   puts "p#{f.page} [#{f.kind}] #{f.message}"
# end
# ```
module PdfAudit
end
