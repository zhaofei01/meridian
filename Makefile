.PHONY: test app image dmg run

test:
	swift build --product MeridianChecks
	.build/debug/MeridianChecks

app:
	Scripts/package-app.sh

image:
	python3 Scripts/build-guest-image.py \
		--output "$$HOME/Library/Application Support/Meridian/GuestImage" \
		--agent Guest/meridian-agent.py \
		--init Guest/guest-init.sh

dmg: app
	Scripts/package-dmg.sh

run: app
	open dist/Meridian.app
