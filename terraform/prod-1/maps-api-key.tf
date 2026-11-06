# Adopts the hand-minted prod Maps key into module.env_base's
# google_apikeys_key. The plan reads as an import with no changes; once the
# apply has recorded it in state, delete this file — a leftover import block
# is a no-op that terraform warns about on every plan.
import {
  to = module.env_base.google_apikeys_key.maps
  id = "projects/876608406330/locations/global/keys/2a87a600-38b5-4a5f-a6bb-d917206a286a"
}
