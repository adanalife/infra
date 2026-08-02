# The round-set media for guessr (github.com/adanalife/guessr) — the mp4 clips
# a player is shown, which the repo deliberately does not carry.
#
# A round used to be a JPEG and the set was committed: ~27 MB, regenerated a few
# times a year, and a deploy could just serve what was in the tree. Rounds are
# now three seconds of footage, which puts a set at ~150 MB, and guessr is a
# public repo — committing one would add that to git history on every
# regeneration, permanently and unrecoverably. So the manifest stays in git
# (functions/api/score.js imports rounds.json at build time, which is what makes
# the server's daily draw provably the same five rounds the page handed out) and
# the media comes from here.
#
# The write is `task clips:push` from the laptop, because the clips are cut from
# the dashcam corpus and nothing in CI can reach it. The read is a step in each
# of guessr's three deploy workflows, which pull the tarball into web/ before
# handing the directory to `wrangler pages deploy`.
#
# Cost: R2 charges nothing for egress, by design, and a set is ~150 MB against
# 10 GB of free storage. This is why the media went to R2 rather than staying a
# Pages asset sourced from git — not bandwidth, which Pages does not bill for
# either, but the one-way door of putting it in a public repo's history.
resource "cloudflare_r2_bucket" "guessr_clips" {
  account_id = var.cloudflare_account_id
  name       = "adanalife-guessr-clips"

  # Same continent as the players and as the Pages projects that read it.
  location = "WNAM"
}

# Deliberately one bucket for all three tiers, where the answers are one D1 per
# tier. The two look symmetrical and are not.
#
# An answer row is a claim about the *current* set — regenerate for staging and
# production's coordinates would be wrong for rounds production is still
# serving, so those have to be separated. A clip is just bytes named after the
# corpus clip it came from, and a tier plays whichever ones its own committed
# manifest names. One bucket holding every set ever pushed means production on
# an old release and staging on main both find what they are looking for, and a
# regeneration adds objects rather than invalidating anyone's.
#
# Nothing is ever deleted here for that reason: an object still named by some
# deployed manifest is load-bearing, and at 150 MB a set there is no pressure to
# find out which. Lifecycle rules are deliberately absent rather than forgotten.
#
# Living in prod-1 rather than core because that is where the cloudflare provider
# and its API token already are (cloudflare-pages.tf); core has neither, and
# standing a third copy up for one bucket is more moving parts than the shared
# resource is worth. Nothing in stage-1 references this — the staging workflow
# reaches it by name, not through terraform.
output "guessr_clips_bucket" {
  description = "R2 bucket holding guessr's round-set clips, read by its deploy workflows"
  value       = cloudflare_r2_bucket.guessr_clips.name
}
