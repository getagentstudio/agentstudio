interface BridgeFileViewerContentHeaderTitleProps {
	readonly selectedPath: string | null;
	readonly sourceId: string;
}

export function bridgeFileViewerContentHeaderTitle({
	selectedPath,
}: BridgeFileViewerContentHeaderTitleProps): string {
	return selectedPath ?? 'Files';
}
