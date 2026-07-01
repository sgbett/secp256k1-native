# Docs site — Jekyll + just-the-docs

## Local workflow

    bundle exec rake docs:generate   # YARD into docs/reference/
    bundle exec rake docs:build      # jekyll build into docs/_site/
    bundle exec rake docs:serve      # jekyll serve --livereload
    bundle exec rake docs:lint       # frontmatter assertions
    bundle exec rake docs:proofread  # htmlproofer (offline)

Or run the lot: `bundle exec rake docs`.

## Rollback

If a deploy is broken and a fix-forward isn't immediate:

1. Settings → Pages → Source: switch back to "Deploy from a branch".
2. Point at the `gh-pages-mkdocs-final` tag (tagged before cutover; see HLR #33).

Project standard forbids `git revert`. Fix-forward on master once `gh-pages` is serving a stable artefact.
