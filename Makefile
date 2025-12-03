.PHONY: all test build examples clean kitchen-sim simple kitchen abandonment multicycle multiworker

all: test

test:
	zig build test

build:
	zig build

# Interactive kitchen simulator game
kitchen-sim:
	zig build kitchen-sim

# Individual examples
simple:
	zig build simple

kitchen:
	zig build kitchen

abandonment:
	zig build abandonment

multicycle:
	zig build multicycle

multiworker:
	zig build multiworker

# Run all examples
examples:
	zig build examples

clean:
	rm -rf .zig-cache zig-out
