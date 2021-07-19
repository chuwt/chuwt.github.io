run:
	@hugo server -D
hugo:
	@rm -rf docs
	@hugo -d docs
	@git add .
	@git commit -m "update md"