require "./manifest"
require "./linter"

module PdfAudit
  # Génère un PDF de rapport listant les anomalies détectées.
  # v0.1.0 : rapport TEXTE seul (pas d'overlay sur le PDF source —
  # le shard `pdf` étant un générateur, modifier un PDF existant
  # demanderait un parser PDF en écriture qu'on n'a pas).
  #
  # Le rapport contient :
  #   - En-tête : nom du PDF audité + métriques globales
  #   - Sections par type d'anomalie
  #   - Pour chaque finding : page, position, message, texte concerné
  #
  # Stratégie : on écrit le rapport en TEXTE BRUT (`.txt`) si le
  # chemin de sortie finit par `.txt`, sinon on essaie d'utiliser
  # le shard `pdf` pour générer un PDF. v0.1.0 ne fait QUE le
  # texte brut — l'intégration shard pdf viendra en v0.2.0.
  module Annotator
    extend self

    def write_report(source_pdf : String, manifest : Manifest,
                     findings : Array(Linter::Finding), out_path : String) : Nil
      content = build_text_report(source_pdf, manifest, findings)
      File.write(out_path, content)
    end

    private def build_text_report(source_pdf : String, manifest : Manifest,
                                  findings : Array(Linter::Finding)) : String
      String.build do |io|
        io << "# pdf-audit — rapport d'anomalies\n"
        io << "\n"
        io << "Source     : #{source_pdf}\n"
        io << "SHA-256    : #{manifest.sha256}\n"
        io << "Bytes      : #{manifest.byte_size}\n"
        io << "Pages      : #{manifest.page_count}\n"
        io << "Total mots : #{manifest.total_words}\n"
        io << "Anomalies  : #{findings.size}\n"
        io << "\n"
        io << "─" * 60
        io << "\n\n"

        if findings.empty?
          io << "✓ Aucune anomalie détectée.\n"
          next
        end

        findings.group_by(&.kind).each do |kind, list|
          io << "## #{kind} (#{list.size}×)\n\n"
          list.each do |f|
            io << "  page #{f.page}  #{f.message}\n"
            io << "    bbox = (#{f.x_min.round(1)}, #{f.y_min.round(1)}) → "
            io << "(#{f.x_max.round(1)}, #{f.y_max.round(1)})\n"
            io << "    text = #{f.text.inspect}\n"
            io << "\n"
          end
        end
      end
    end
  end
end
