# Fast Development Turn around
For faster development, running the mod with an unpacked zip file and rsyncing the source into said folder is faster than building a .zip

`rsync -avh --delete --exclude='.git/' --filter=':- .gitignore' --filter=":- .rsyncignore" "$(pwd)/" "${HOME}/.local/share/BeamNG/BeamNG.drive/current/mods/unpacked/rls_career_overhaul_${version}/"`

Replacing `${version}` with the version string (2.8.1-rc1 etc..)


# Installing a built zip
Installing a built zip is easy, after building the package, run the following command:

`install "./dist/rls_career_overhaul_v2.8.1-rc1.zip" "${HOME}/.local/share/BeamNG/BeamNG.drive/current/mods/" --mode=0600`