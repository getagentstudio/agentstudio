// Loaded only by test-owned Vite children. The parent holds stdin open; an
// abrupt parent death requests the same SIGTERM used by normal owned teardown.
process.stdin.resume();
process.stdin.once('end', (): void => {
	process.kill(process.pid, 'SIGTERM');
});

export {};
