require "./spec_helper"

describe PdfAudit::Manifest do
  pdf = "/tmp/pdfs-baseline-v81/beryl.pdf"

  it "extracts a manifest from a real PDF" do
    pending! "no baseline PDF at #{pdf}" unless File.exists?(pdf)
    m = PdfAudit::Manifest.from_pdf(pdf)
    m.path.should eq pdf
    m.sha256.size.should eq 64
    m.byte_size.should be > 0
    m.page_count.should be > 0
    m.total_words.should be > 100
  end

  it "round-trips through YAML" do
    pending! "no baseline PDF at #{pdf}" unless File.exists?(pdf)
    m = PdfAudit::Manifest.from_pdf(pdf)
    y = m.to_yaml
    m2 = PdfAudit::Manifest.from_yaml(y)
    m2.sha256.should eq m.sha256
    m2.total_words.should eq m.total_words
  end
end

describe PdfAudit::Differ do
  pdf = "/tmp/pdfs-baseline-v81/beryl.pdf"

  it "reports identical when comparing a manifest to itself" do
    pending! "no baseline PDF at #{pdf}" unless File.exists?(pdf)
    m = PdfAudit::Manifest.from_pdf(pdf)
    diff = PdfAudit::Differ.diff(m, m)
    diff.identical.should be_true
    diff.changed_sha.should be_false
    diff.word_delta.should eq 0
  end
end

describe PdfAudit::Linter do
  pdf = "/tmp/pdfs-baseline-v81/beryl.pdf"

  it "produces a list of typographic findings" do
    pending! "no baseline PDF at #{pdf}" unless File.exists?(pdf)
    m = PdfAudit::Manifest.from_pdf(pdf)
    findings = PdfAudit::Linter.lint(m)
    # On s'attend à au moins quelques findings sur le README
    # beryl qui a des longues commandes et codespans.
    findings.size.should be > 0
    findings.first.kind.should be_a Symbol
  end

  it "respects the right_margin_pt option" do
    pending! "no baseline PDF at #{pdf}" unless File.exists?(pdf)
    m = PdfAudit::Manifest.from_pdf(pdf)
    # Plus la marge est LARGE, plus target_right = page_width -
    # margin est PETIT, donc plus de mots dépassent → plus de
    # findings. Inversement, marge étroite = peu de findings.
    strict_few = PdfAudit::Linter::Options.new(right_margin_pt: 0.1)
    lax_many = PdfAudit::Linter::Options.new(right_margin_pt: 100.0)
    PdfAudit::Linter.lint(m, lax_many).size.should be > PdfAudit::Linter.lint(m, strict_few).size
  end
end

describe PdfAudit::Annotator do
  pdf = "/tmp/pdfs-baseline-v81/beryl.pdf"

  it "writes a text report listing findings" do
    pending! "no baseline PDF at #{pdf}" unless File.exists?(pdf)
    m = PdfAudit::Manifest.from_pdf(pdf)
    findings = PdfAudit::Linter.lint(m)
    report_path = "/tmp/pdf-audit-test-report.txt"
    File.delete(report_path) if File.exists?(report_path)
    PdfAudit::Annotator.write_report(pdf, m, findings, report_path)
    File.exists?(report_path).should be_true
    content = File.read(report_path)
    content.should contain "pdf-audit"
    content.should contain "Anomalies"
  end
end
