run:
	@hugo server -D
hugo:
	@hugo -d docs
	@git add .
	@git commit -m "update md"