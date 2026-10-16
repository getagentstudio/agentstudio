import AgentStudioInfrastructure
import AppKit
import Foundation
import GhosttyKit

extension Ghostty.SurfaceView {
    func handleCloseRequested() -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let processExited = self.processExited
            RestoreTrace.log(
                "Ghostty.SurfaceView.closeRequest processExited=\(processExited) mainThread=\(Thread.isMainThread)"
            )
            let completion = self.onCloseRequested?(processExited)
            await completion?.value
        }
    }
}

extension Ghostty.SurfaceView {
    func metricsSnapshotDescription() -> String {
        guard let surface else {
            return "surface=nil"
        }

        let metrics = ghostty_surface_size(surface)
        let initialSizeDescription = reportedInitialSize.map(NSStringFromSize) ?? "nil"
        let cellSizeDescription = reportedCellSize.map(NSStringFromSize) ?? "nil"
        return
            "frame=\(NSStringFromRect(frame)) bounds=\(NSStringFromRect(bounds)) contentSize=\(NSStringFromSize(contentSize)) initialSize=\(initialSizeDescription) cellSize=\(cellSizeDescription) columns=\(metrics.columns) rows=\(metrics.rows) widthPx=\(metrics.width_px) heightPx=\(metrics.height_px) cellWidthPx=\(metrics.cell_width_px) cellHeightPx=\(metrics.cell_height_px) focused=\(focused) window=\(window != nil)"
    }

    func logSurfaceSnapshot(reason: String) {
        RestoreTrace.log("Ghostty.SurfaceView.snapshot reason=\(reason) \(metricsSnapshotDescription())")
    }
}
