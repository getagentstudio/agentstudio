import AgentStudioInfrastructure
import Foundation

enum BridgePaneProductReviewMetadataSourceError: Error, Equatable {
    case integerOutOfRange
    case metadataEventExceedsByteLimit
    case unavailablePackage
    case unknownSubscription
}

struct BridgeReviewMetadataPublicationReservation: Equatable, Sendable {
    let reservationId: UUID
    let packageId: String
    let publicationId: UUID
    let reviewGeneration: BridgeReviewGeneration
    let revision: Int
    let projectionPlan: BridgeReviewMetadataPublicationProjectionPlan
}

struct BridgeReviewMetadataFinalFrame: Equatable, Sendable {
    let sequence: Int
    let subscriptionId: String
}

struct BridgeReviewMetadataPublicationReceipt: Equatable, Sendable {
    let retained: Int
    let publishedSubscriptions: Int
    let emittedEvents: Int
    let superseded: Int
    let finalFrames: [BridgeReviewMetadataFinalFrame]
}

enum BridgePaneProductReviewMetadataPublicationOutcome: Equatable, Sendable {
    case delivered(BridgeReviewMetadataPublicationReceipt)
    case deferred(retained: Int)
}

protocol BridgePaneProductReviewMetadataProducing: Sendable {
    func applyViewDemand(_ request: BridgePaneProductReviewViewDemandRequest) async throws
        -> BridgePaneProductReviewViewCapture?
    func open(
        subscription: BridgeProductSubscriptionSnapshot,
        productAdmission: BridgeProductAdmissionContext
    ) async throws
    func reserve(
        package: BridgeReviewPackage,
        publicationId: UUID,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> BridgeReviewMetadataPublicationReservation
    func deliver(
        publication: BridgeReviewCommittedPublication,
        reservation: BridgeReviewMetadataPublicationReservation,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> BridgePaneProductReviewMetadataPublicationOutcome
    func cancel(subscriptionId: String) async
}

struct BridgePaneProductReviewViewCapture: Sendable {
    let handle: String
    let scopeRevision: Int
    let publicationId: UUID
    let snapshot: BridgeProductReviewKeyedSnapshot
}

struct BridgePaneProductReviewViewDemandRequest: Sendable {
    let subscriptionId: String
    let handle: String
    let scopeRevision: Int
    let admissionSequence: Int
    let demand: BridgeProductReviewMetadataInterestState
    let expectedPublicationId: UUID
    let productAdmission: BridgeProductAdmissionContext
}

extension BridgePaneProductReviewMetadataProducing {
    func applyViewDemand(_: BridgePaneProductReviewViewDemandRequest) async throws
        -> BridgePaneProductReviewViewCapture?
    { nil }
}

actor BridgeUnavailablePaneProductReviewMetadataSource: BridgePaneProductReviewMetadataProducing {
    func open(
        subscription _: BridgeProductSubscriptionSnapshot,
        productAdmission _: BridgeProductAdmissionContext
    ) async throws {
        throw BridgePaneProductReviewMetadataSourceError.unavailablePackage
    }

    func reserve(
        package _: BridgeReviewPackage,
        publicationId _: UUID,
        productAdmission _: BridgeProductAdmissionContext
    ) async throws -> BridgeReviewMetadataPublicationReservation {
        throw BridgePaneProductReviewMetadataSourceError.unavailablePackage
    }

    func deliver(
        publication _: BridgeReviewCommittedPublication,
        reservation _: BridgeReviewMetadataPublicationReservation,
        productAdmission _: BridgeProductAdmissionContext
    ) async throws -> BridgePaneProductReviewMetadataPublicationOutcome {
        .deferred(retained: 0)
    }

    func cancel(subscriptionId _: String) {}
}

actor BridgePaneProductReviewMetadataSource: BridgePaneProductReviewMetadataProducing {
    fileprivate struct DeliveredPublication: Sendable {
        let classifiedRefreshImpact: BridgeReviewRefreshImpact?
        let package: BridgeReviewPackage
        let publicationId: UUID
        let reviewComparison: BridgePaneReviewComparisonPresentation?
        let viewRevision: Int
    }

    private enum EmissionOutcome {
        case published(eventCount: Int, finalFrameSequence: Int?)
        case superseded
    }

    private struct SubscriptionContext: Sendable {
        let contextId: UUID
        var deliveredPublication: DeliveredPublication?
        var appliedViewDemand: AppliedViewDemand?
        var subscription: BridgeProductSubscriptionSnapshot
    }

    private struct AppliedViewDemand: Equatable, Sendable {
        let demand: BridgeProductReviewMetadataInterestState
        let handle: String
        let scopeRevision: Int
        let admissionSequence: Int
    }

    private var deliveryRevision = 0
    private var contextBySubscriptionId: [String: SubscriptionContext] = [:]

    func applyViewDemand(_ request: BridgePaneProductReviewViewDemandRequest) async throws
        -> BridgePaneProductReviewViewCapture?
    {
        guard request.productAdmission.withValidAdmission({ true }) == true,
            var context = contextBySubscriptionId[request.subscriptionId],
            context.subscription.subscriptionKind == .reviewMetadata,
            request.scopeRevision >= 0
        else { return nil }
        let appliedDemand = AppliedViewDemand(
            demand: request.demand,
            handle: request.handle,
            scopeRevision: request.scopeRevision,
            admissionSequence: request.admissionSequence
        )
        if let currentDemand = context.appliedViewDemand {
            guard request.admissionSequence >= currentDemand.admissionSequence else { return nil }
            if request.admissionSequence == currentDemand.admissionSequence {
                guard currentDemand == appliedDemand else { return nil }
            } else if currentDemand.handle == request.handle {
                guard request.scopeRevision > currentDemand.scopeRevision else { return nil }
            }
        }
        context.appliedViewDemand = appliedDemand
        contextBySubscriptionId[request.subscriptionId] = context
        guard let delivered = context.deliveredPublication,
            delivered.publicationId == request.expectedPublicationId
        else { return nil }
        let orderedItemIds = BridgePaneProductReviewMetadataSource.orderedItemIds(in: delivered.package)
        let revisionsForPackage = Dictionary(uniqueKeysWithValues: orderedItemIds.map { ($0, delivered.viewRevision) })
        let items = try BridgeProductReviewBatchItemProjection.initialItems(
            in: delivered.package,
            revisionByItemId: revisionsForPackage
        )
        let publication = try BridgeProductReviewBatchPublicationProjection.record(
            from: .init(
                classifiedRefreshImpact: delivered.classifiedRefreshImpact,
                publicationId: delivered.publicationId,
                revision: delivered.viewRevision,
                desiredComparison: delivered.reviewComparison,
                desiredStatus: .ready,
                displayedPackage: delivered.package,
                displayedPublicationId: delivered.publicationId,
                displayedComparison: delivered.reviewComparison
            )
        )
        let snapshot = BridgeProductReviewKeyedSnapshot(
            targetRevision: delivered.viewRevision,
            publication: publication,
            items: items
        )
        return BridgePaneProductReviewViewCapture(
            handle: request.handle,
            scopeRevision: request.scopeRevision,
            publicationId: delivered.publicationId,
            snapshot: snapshot
        )
    }

    func open(
        subscription: BridgeProductSubscriptionSnapshot,
        productAdmission: BridgeProductAdmissionContext
    ) async throws {
        guard subscription.subscriptionKind == .reviewMetadata
        else {
            throw BridgePaneProductReviewMetadataSourceError.unavailablePackage
        }
        _ = productAdmission.withValidAdmission {
            contextBySubscriptionId[subscription.subscriptionId] = SubscriptionContext(
                contextId: UUID(),
                deliveredPublication: nil,
                appliedViewDemand: nil,
                subscription: subscription
            )
        }
    }

    func reserve(
        package: BridgeReviewPackage,
        publicationId: UUID,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> BridgeReviewMetadataPublicationReservation {
        let projectionPlan = try BridgeReviewMetadataPublicationProjectionPlan.prepare(
            package: package,
            publicationId: publicationId
        )
        guard (productAdmission.withValidAdmission { true }) == true else {
            throw CancellationError()
        }
        return BridgeReviewMetadataPublicationReservation(
            reservationId: UUIDv7.generate(),
            packageId: package.packageId,
            publicationId: publicationId,
            reviewGeneration: package.reviewGeneration,
            revision: package.revision,
            projectionPlan: projectionPlan
        )
    }

    func deliver(
        publication: BridgeReviewCommittedPublication,
        reservation: BridgeReviewMetadataPublicationReservation,
        productAdmission: BridgeProductAdmissionContext
    ) async throws -> BridgePaneProductReviewMetadataPublicationOutcome {
        let package = publication.package
        guard reservation.packageId == package.packageId,
            reservation.reviewGeneration == package.reviewGeneration,
            reservation.revision == package.revision,
            reservation.projectionPlan.packageId == package.packageId,
            reservation.projectionPlan.publicationId == reservation.publicationId,
            reservation.projectionPlan.reviewGeneration == package.reviewGeneration,
            reservation.projectionPlan.revision == package.revision,
            (productAdmission.withValidAdmission { true }) == true
        else { throw BridgePaneProductReviewMetadataSourceError.unavailablePackage }
        let subscriptionIds = contextBySubscriptionId.keys.sorted()
        guard !subscriptionIds.isEmpty else { return .deferred(retained: 0) }
        guard
            let publishingDeliveryRevision = productAdmission.withValidAdmission({
                deliveryRevision += 1
                return deliveryRevision
            })
        else { return .deferred(retained: 0) }
        var emittedEventCount = 0
        var publishedSubscriptionCount = 0
        var supersededSubscriptionCount = 0
        var finalFrames: [BridgeReviewMetadataFinalFrame] = []
        for subscriptionId in subscriptionIds {
            try Task.checkCancellation()
            guard let context = contextBySubscriptionId[subscriptionId] else { continue }
            switch installIfCurrent(
                DeliveredPublication(
                    classifiedRefreshImpact: publication.classifiedRefreshImpact,
                    package: package,
                    publicationId: reservation.publicationId,
                    reviewComparison: publication.reviewComparison,
                    viewRevision: publishingDeliveryRevision
                ),
                context: context,
                deliveryRevision: publishingDeliveryRevision,
                productAdmission: productAdmission
            ) {
            case .published(let eventCount, let finalFrameSequence):
                emittedEventCount += eventCount
                publishedSubscriptionCount += 1
                if let finalFrameSequence {
                    finalFrames.append(
                        BridgeReviewMetadataFinalFrame(
                            sequence: finalFrameSequence,
                            subscriptionId: subscriptionId
                        )
                    )
                }
            case .superseded:
                supersededSubscriptionCount += 1
            }
        }
        return .delivered(
            BridgeReviewMetadataPublicationReceipt(
                retained: subscriptionIds.count,
                publishedSubscriptions: publishedSubscriptionCount,
                emittedEvents: emittedEventCount,
                superseded: supersededSubscriptionCount,
                finalFrames: finalFrames
            ))
    }

    func cancel(subscriptionId: String) {
        contextBySubscriptionId.removeValue(forKey: subscriptionId)
    }

    private func installIfCurrent(
        _ publication: DeliveredPublication,
        context: SubscriptionContext,
        deliveryRevision publishingDeliveryRevision: Int,
        productAdmission: BridgeProductAdmissionContext
    ) -> EmissionOutcome {
        productAdmission.withValidAdmission {
            guard var currentContext = contextBySubscriptionId[context.subscription.subscriptionId],
                currentContext.contextId == context.contextId,
                deliveryRevision == publishingDeliveryRevision
            else { return .superseded }
            currentContext.deliveredPublication = publication
            contextBySubscriptionId[context.subscription.subscriptionId] = currentContext
            return .published(
                eventCount: 0,
                finalFrameSequence: nil
            )
        } ?? .superseded
    }

    static func orderedItemIds(in package: BridgeReviewPackage) -> [String] {
        var seen = Set<String>()
        var itemIds = package.orderedItemIds.filter { package.itemsById[$0] != nil && seen.insert($0).inserted }
        itemIds.append(contentsOf: package.itemsById.keys.sorted().filter { seen.insert($0).inserted })
        return itemIds
    }
}
