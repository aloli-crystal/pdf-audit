require "option_parser"
require "json"
require "./pdf_audit"

# pdf-audit — audit visuel de PDFs.
# Conventions UX ALOLI : `help [<sub>]` positionnel, shorts sur
# tous les flags long, refus explicite des sous-commandes inconnues.

USAGE_GLOBAL = <<-USAGE
  pdf-audit — Visual audit toolkit for PDFs (v#{PdfAudit::VERSION}).

  Usage :
    pdf-audit <command> [options]
    pdf-audit help [<command>]

  Commandes :
    baseline   Extrait le manifest YAML d'un PDF
    diff       Compare deux manifests (régression visuelle)
    lint       Détecte les anomalies typographiques d'un PDF
    annotate   Génère un rapport des anomalies
    help       Affiche cette aide
    version    Affiche la version

  Options globales :
    -V, --version    Affiche la version
    -h, --help       Affiche cette aide
  USAGE

HELP_BASELINE = <<-USAGE
  Usage : pdf-audit baseline <fichier.pdf> [-o FILE] [-j]

  Extrait le manifest YAML d'un PDF (sha256, dimensions, mots
  avec bbox). Sert de référence pour `pdf-audit diff`.

    -o, --out FILE    Écrit dans FILE (défaut : stdout)
    -j, --json        Sortie JSON au lieu de YAML
    -h, --help        Affiche cette aide
  USAGE

HELP_DIFF = <<-USAGE
  Usage : pdf-audit diff <baseline.yml> <after.yml> [-j]
          pdf-audit diff <baseline_dir/> <after_dir/> [-j]

  Compare 2 manifests (ou 2 dossiers de manifests). Exit 0 si
  identique, 1 si différences.

    -j, --json        Sortie JSON
    -h, --help        Affiche cette aide
  USAGE

HELP_LINT = <<-USAGE
  Usage : pdf-audit lint <fichier.pdf> [-m PT] [-g PT] [-j]

  Détecte les anomalies typographiques :
    - mots débordant la marge droite
    - mots collés ou chevauchants
    - gap excessif entre 2 mots (justification cassée)
    - ponctuation orpheline en début de ligne

    -m, --margin PT   Marge droite attendue (défaut : 36 pt)
    -g, --max-gap PT  Seuil de gap excessif (défaut : 20 pt)
    -j, --json        Sortie JSON
    -h, --help        Affiche cette aide
  USAGE

HELP_ANNOTATE = <<-USAGE
  Usage : pdf-audit annotate <fichier.pdf> -o <rapport.txt> [-m PT]

  Génère un rapport listant les anomalies détectées par `lint`,
  avec le contexte (page, position, message). v0.1.0 produit
  un rapport texte ; le PDF natif viendra en v0.2.0.

    -o, --out FILE    Chemin du rapport (REQUIS)
    -m, --margin PT   Marge droite attendue (défaut : 36 pt)
    -h, --help        Affiche cette aide
  USAGE

def show_help_for(sub : String?) : Int32
  case sub
  when nil, "", "help" then puts USAGE_GLOBAL
  when "baseline"      then puts HELP_BASELINE
  when "diff"          then puts HELP_DIFF
  when "lint"          then puts HELP_LINT
  when "annotate"      then puts HELP_ANNOTATE
  when "version"       then puts "pdf-audit #{PdfAudit::VERSION}"
  else
    STDERR.puts "Sous-commande inconnue : « #{sub} »."
    STDERR.puts "Commandes : baseline, diff, lint, annotate, help, version"
    return 2
  end
  0
end

def parse_subargs(args, help_text, &)
  positional = [] of String
  parser = OptionParser.new do |op|
    yield op
    op.on("-h", "--help", "Help") { puts help_text; exit 0 }
  end
  parser.unknown_args { |a| positional = a }
  parser.parse(args)
  positional
end

def cmd_baseline(args : Array(String)) : Int32
  out_path = nil.as(String?)
  json_out = false
  positional = parse_subargs(args, HELP_BASELINE) do |op|
    op.on("-o FILE", "--out FILE", "Output") { |v| out_path = v }
    op.on("-j", "--json", "JSON") { json_out = true }
  end
  if positional.empty?
    STDERR.puts "Erreur : fichier PDF requis."
    STDERR.puts HELP_BASELINE
    return 2
  end
  pdf = positional.first
  unless File.exists?(pdf)
    STDERR.puts "Erreur : fichier introuvable : #{pdf}"
    return 2
  end
  manifest = PdfAudit::Manifest.from_pdf(pdf)
  serialized = json_out ? manifest.to_json : manifest.to_yaml
  if (o = out_path)
    File.write(o, serialized)
    puts "Manifest écrit : #{o} (#{manifest.page_count} pages, #{manifest.total_words} mots)"
  else
    puts serialized
  end
  0
end

def cmd_diff(args : Array(String)) : Int32
  json_out = false
  positional = parse_subargs(args, HELP_DIFF) do |op|
    op.on("-j", "--json", "JSON") { json_out = true }
  end
  if positional.size != 2
    STDERR.puts "Erreur : 2 arguments requis (baseline + after)."
    STDERR.puts HELP_DIFF
    return 2
  end
  a, b = positional
  if File.directory?(a) && File.directory?(b)
    diffs = PdfAudit::Differ.diff_dirs(a, b)
    if json_out
      puts diffs.transform_values(&.to_json).to_json
    else
      changed = diffs.reject { |_, d| d.identical }
      puts "Projets identiques : #{diffs.size - changed.size}/#{diffs.size}"
      changed.each do |name, d|
        printf "  %-40s pages%+d mots%+d page-deltas:%d\n",
          name, d.page_delta, d.word_delta, d.pages_word_delta.size
      end
    end
    diffs.values.all?(&.identical) ? 0 : 1
  elsif File.file?(a) && File.file?(b)
    baseline = PdfAudit::Manifest.from_yaml(File.read(a))
    after = PdfAudit::Manifest.from_yaml(File.read(b))
    diff = PdfAudit::Differ.diff(baseline, after)
    if json_out
      puts diff.to_json
    else
      puts "SHA changé : #{diff.changed_sha}"
      puts "Bytes      : #{diff.byte_delta >= 0 ? "+" : ""}#{diff.byte_delta}"
      puts "Pages      : #{diff.page_delta >= 0 ? "+" : ""}#{diff.page_delta}"
      puts "Mots       : #{diff.word_delta >= 0 ? "+" : ""}#{diff.word_delta}"
      unless diff.pages_word_delta.empty?
        puts "Par page :"
        diff.pages_word_delta.each do |pd|
          puts "  page #{pd.page} : #{pd.baseline} → #{pd.after} (#{pd.delta >= 0 ? "+" : ""}#{pd.delta})"
        end
      end
    end
    diff.identical ? 0 : 1
  else
    STDERR.puts "Erreur : arguments doivent être 2 fichiers OU 2 dossiers."
    2
  end
end

def cmd_lint(args : Array(String)) : Int32
  margin = 36.0
  max_gap = 20.0
  json_out = false
  positional = parse_subargs(args, HELP_LINT) do |op|
    op.on("-m PT", "--margin PT", "Margin") { |v| margin = v.to_f }
    op.on("-g PT", "--max-gap PT", "Max gap") { |v| max_gap = v.to_f }
    op.on("-j", "--json", "JSON") { json_out = true }
  end
  if positional.empty?
    STDERR.puts "Erreur : fichier PDF requis."
    STDERR.puts HELP_LINT
    return 2
  end
  pdf = positional.first
  unless File.exists?(pdf)
    STDERR.puts "Erreur : fichier introuvable : #{pdf}"
    return 2
  end
  manifest = PdfAudit::Manifest.from_pdf(pdf)
  opts = PdfAudit::Linter::Options.new(right_margin_pt: margin, max_gap_pt: max_gap)
  findings = PdfAudit::Linter.lint(manifest, opts)
  if json_out
    puts findings.map(&.to_h).to_json
  elsif findings.empty?
    puts "✓ Aucune anomalie (#{manifest.page_count} pages, #{manifest.total_words} mots)."
  else
    puts "#{findings.size} anomalie#{findings.size > 1 ? "s" : ""} :"
    findings.group_by(&.kind).each do |kind, list|
      puts ""
      puts "  [#{kind}] #{list.size}×"
      list.first(5).each { |f| printf "    p%d  %s\n", f.page, f.message }
      puts "    … (#{list.size - 5} autres)" if list.size > 5
    end
  end
  findings.empty? ? 0 : 1
end

def cmd_annotate(args : Array(String)) : Int32
  out_path = nil.as(String?)
  margin = 36.0
  positional = parse_subargs(args, HELP_ANNOTATE) do |op|
    op.on("-o FILE", "--out FILE", "Output") { |v| out_path = v }
    op.on("-m PT", "--margin PT", "Margin") { |v| margin = v.to_f }
  end
  if positional.empty? || out_path.nil?
    STDERR.puts "Erreur : <fichier.pdf> ET -o <rapport> requis."
    STDERR.puts HELP_ANNOTATE
    return 2
  end
  pdf = positional.first
  unless File.exists?(pdf)
    STDERR.puts "Erreur : fichier introuvable : #{pdf}"
    return 2
  end
  manifest = PdfAudit::Manifest.from_pdf(pdf)
  opts = PdfAudit::Linter::Options.new(right_margin_pt: margin)
  findings = PdfAudit::Linter.lint(manifest, opts)
  PdfAudit::Annotator.write_report(pdf, manifest, findings, out_path.not_nil!)
  puts "Rapport écrit : #{out_path} (#{findings.size} anomalies)"
  findings.empty? ? 0 : 1
end

# Main dispatch
if ARGV.empty? || ARGV[0] == "-h" || ARGV[0] == "--help"
  puts USAGE_GLOBAL
  exit 0
end

if ARGV[0] == "-V" || ARGV[0] == "--version" || ARGV[0] == "version"
  puts "pdf-audit #{PdfAudit::VERSION}"
  exit 0
end

cmd, rest = ARGV[0], ARGV[1..]
exit case cmd
when "help"     then show_help_for(rest.first?)
when "baseline" then cmd_baseline(rest)
when "diff"     then cmd_diff(rest)
when "lint"     then cmd_lint(rest)
when "annotate" then cmd_annotate(rest)
else
  STDERR.puts "Sous-commande inconnue : « #{cmd} »."
  STDERR.puts "Voir `pdf-audit help` pour la liste."
  2
end
