# Imagery manifest for `mix contract.imagegen`.
#
# Each entry: {slug, prompt, size, quality, output_path}. The Mix task
# decodes this with `Code.eval_file/1`, POSTs each to OpenAI's
# `gpt-image-1` model, and writes the resulting PNG to output_path.
#
# Quality "medium" hits the sweet spot between cost and crispness for
# line-art marketing illustrations. 1536x1024 for the hero (≈$0.06 per
# render); 1024x1024 for feature blocks (≈$0.04); 1024x1024 for the
# dashboard empty state (≈$0.04). Total ≈ $0.22 per full regen.
#
# Style budget (see feedback-generated-imagery memory):
#   - Minimal line-art, monochrome with a single emerald (#10b981) accent.
#   - No human faces, no specific brand logos, no shimmer / gradient.
#   - Editorial illustration tone — Linear / Notion / Cursor marketing.

[
  %{
    slug: "hero",
    prompt: """
    Minimal editorial line-art illustration. ABSOLUTELY NO HUMAN FIGURES, NO
    SILHOUETTES, NO HOODED CHARACTERS, NO MASCOTS, NO HANDS, NO FACES. The subject
    is a single legal-document page floating on a clean off-white background, with
    3-4 short text lines abstracted as horizontal rules. Above the page, three
    small soft question marks float (rendered as outline strokes). One line of
    text on the page is highlighted with a thin emerald (#10b981) underline. The
    composition is calm, geometric, mathematically restrained — reminiscent of
    Swiss editorial design or Bauhaus-style technical illustration. Thin even
    line weight (1-1.5pt), no shading, no gradients, no realistic textures, no
    decorative flourishes. 16:9 composition with negative space on the right
    third for overlaid headline text. Black-and-white plus one emerald accent
    ONLY. Style references: Massimo Vignelli, Dieter Rams diagrams, technical
    manual illustrations.
    """,
    size: "1536x1024",
    quality: "medium",
    output_path: "priv/static/images/landing/hero.png"
  },
  %{
    slug: "feature-grill-me",
    prompt: """
    Minimal line-art icon-illustration. Subject: a hand pausing over a contract
    paragraph, with three soft question marks floating above the text — depicting
    an AI agent that asks clarifying questions before editing. Monochrome black on
    white with one emerald (#10b981) accent on the question marks. Thin even line
    weight, no shading, no clip-art look. Square 1:1 composition, centered.
    """,
    size: "1024x1024",
    quality: "medium",
    output_path: "priv/static/images/landing/feature-grill-me.png"
  },
  %{
    slug: "feature-citation",
    prompt: """
    Minimal line-art icon-illustration. Subject: a single short paragraph of
    English-only legal text (5-6 horizontal abstracted lines representing text)
    with a small checkmark stamp aligned to its right edge. Beside it, a
    parallel narrower column shows a single reference label reading exactly
    "ARTICLE 1" in clean uppercase English. ABSOLUTELY NO KOREAN CHARACTERS,
    NO HANGUL, NO HANJA, NO ASIAN-SCRIPT CHARACTERS OF ANY KIND. ABSOLUTELY
    NO HUMAN FIGURES. Monochrome black on off-white with one emerald (#10b981)
    accent on the checkmark only. Thin even line weight (1-1.5pt), no shading.
    Square 1:1 composition, centered. Style: Swiss editorial line-art, Dieter
    Rams technical-manual flavor.
    """,
    size: "1024x1024",
    quality: "medium",
    output_path: "priv/static/images/landing/feature-citation.png"
  },
  %{
    slug: "feature-type-conversion",
    prompt: """
    Minimal line-art icon-illustration. Subject: two parallel document outlines —
    one labelled NDA and one labelled Franchise — connected by thin curved lines
    showing migrated fields (party names, dates, jurisdictions) flowing from one
    to the other while preserving lineage. Monochrome black on white with one
    emerald (#10b981) accent on the migration arrows. Thin even line weight, no
    shading. Square 1:1 composition, centered.
    """,
    size: "1024x1024",
    quality: "medium",
    output_path: "priv/static/images/landing/feature-conversion.png"
  },
  %{
    slug: "dashboard-empty",
    prompt: """
    Minimal line-art illustration. Subject: an empty open folder on a clean desk
    surface, with a single quill resting beside it and a faint emerald (#10b981)
    accent on the folder tab — suggesting "no matters yet, start your first
    document". Monochrome black on white. Thin even line weight, no shading.
    4:3 composition.
    """,
    size: "1024x1024",
    quality: "medium",
    output_path: "priv/static/images/landing/dashboard-empty.png"
  }
]
