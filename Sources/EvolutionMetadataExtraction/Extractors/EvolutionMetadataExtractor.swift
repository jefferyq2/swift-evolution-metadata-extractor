
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2024 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors

import Foundation
import EvolutionMetadataModel

struct EvolutionMetadataExtractor {
    
    static func extractEvolutionMetadata(for extractionJob: ExtractionJob) async throws -> EvolutionMetadata {
        
        let (filteredProposalSpecs, reusableProposals) = filterProposalSpecs(for: extractionJob)
        
        // If writing out a snapshot, will want to write proposal files when fetching.
        // Create the .evosnapshot directory and proposals directory to write to
        if let proposalsDirectoryURL = extractionJob.proposalsDirectoryURL {
            try FileManager.default.createDirectory(at: proposalsDirectoryURL, withIntermediateDirectories: true)
        }

        let proposals = await withTaskGroup(of: Proposal.self, returning: [Proposal].self) { taskGroup in
            
            for spec in filteredProposalSpecs {
                taskGroup.addTask { await readAndExtractProposalMetadata(from: spec, proposalDirectoryURL: extractionJob.proposalsDirectoryURL, extractionDate: extractionJob.extractionDate) }
            }
            
            var proposals: [Proposal] = []
            for await result in taskGroup {
                proposals.append(result)
            }
            
            return proposals
        }
        
        verbosePrint("Reused Proposal Count:", reusableProposals.count, terminator: "\n")
        verbosePrint("Processed Proposal Count:", proposals.count)
        
        // Combine and sort reused and newly extracted proposal metadata
        let combinedProposals = (reusableProposals + proposals).sorted(using: SortDescriptor(\.id))
        
        // Add top-level metadata
        
        // Calculate implementation versions
        var implementationVersionSet: Set<String> = []
        for proposal in combinedProposals {
            if case let Proposal.Status.implemented(version) = proposal.status, !version.isEmpty {
                implementationVersionSet.insert(version)
            }
        }
        let implementationVersions =  implementationVersionSet.sorted(using: SortDescriptor(\.self))
        
        verbosePrint("Implementation Versions:", implementationVersions)
        let formattedExtractionDate = extractionJob.extractionDate.formatted(.iso8601)

        return EvolutionMetadata(
            extractionDate: formattedExtractionDate,
            implementationVersions: implementationVersions,
            proposals: combinedProposals,
            sha: extractionJob.branchInfo?.commit.sha ?? "",
            toolVersion: extractionJob.toolVersion
        )
    }
    
    static func readAndExtractProposalMetadata(from proposalSpec: ProposalSpec, proposalDirectoryURL: URL?, extractionDate: Date) async -> Proposal {
        do {
            let markdownString: String
            if proposalSpec.url.isFileURL {
                markdownString = try String(contentsOf: proposalSpec.url)
            } else {
                markdownString = try await GitHubFetcher.fetchProposalContents(from: proposalSpec.url)
            }
            
            if let proposalDirectoryURL {
                let proposalFileURL = proposalDirectoryURL.appending(component: proposalSpec.filename)
                let data = Data(markdownString.utf8)
                try data.write(to: proposalFileURL)
            }

            let parsedProposal = ProposalMetadataExtractor.extractProposalMetadata(from: markdownString, proposalID: proposalSpec.id, sha: proposalSpec.sha, extractionDate: extractionDate)
            
            // For proposals that fail proposal link / id extraction, provides a way to identify the problem file in validation reports
            // When activated, be sure to set the link back to empty string post-validation report
//            if parsedProposal.link.isEmpty { parsedProposal.link = proposalSpec.name }
            
            // VALIDATION ENHANCEMENT: Validate that the 'link' value matches the filename
            // VALIDATION ENHANCEMENT: Note that items in Malformed test would need to be updated, since their filename matches the problem exhibited
            
            return parsedProposal

        } catch {
            print(error)
            return Proposal(errors:[ValidationIssue.proposalContainsNoContent])
        }
    }
    
    private static func filterProposalSpecs(for extractionJob: ExtractionJob) -> ([ProposalSpec], [Proposal]) {
        
        // If reusableProposals is empty, there can be no reuse. Return early.
        guard !extractionJob.previousResults.isEmpty else {
            return (extractionJob.proposalSpecs, extractionJob.previousResults)
        }
        
        var parsedProposalsById = extractionJob.previousResults.reduce(into: [String:Proposal]()) { $0[$1.id] = $1 }
        var reusableProposals: [Proposal] = []
        var deletedProposals: [Proposal] = []

        let needsParsing = extractionJob.proposalSpecs.reduce(into: [ProposalSpec]()) { partialResult, githubProposal in
            if let parsedProposal = parsedProposalsById.removeValue(forKey: githubProposal.id) {
                if parsedProposal.sha == githubProposal.sha && !extractionJob.forcedExtractionIDs.contains(githubProposal.id) {
                    reusableProposals.append(parsedProposal)
                }
                else {
                    partialResult.append(githubProposal)
                }
            } else {
                partialResult.append(githubProposal)
            }
        }
        
        // Remove deleted proposals from reusable proposals
        for id in parsedProposalsById.keys {
            reusableProposals.removeAll { $0.id == id }
        }
        deletedProposals.append(contentsOf: parsedProposalsById.values)
        
        if needsParsing.count == 0 && deletedProposals.count == 0 {
            print("No proposals require extraction. Using previously extracted results.\n")
        }

        return (needsParsing, reusableProposals)
    }
}

/// A `ProposalSpec` contains the information necessary to extract and generate the metadata for a proposal.
///
/// Each `ProposalSpec` contains the URL to access the contents of the proposal and the SHA value of the proposal.
/// It also includes convenience properties for the filename and proposal ID.
///
/// The listing of proposals to be processed may come from a GitHub proposal listing or scanning the contents of a directory.
struct ProposalSpec: Sendable {
    var url: URL
    var sha: String
    var id: String { "SE-" + url.lastPathComponent.prefix(4) }
    var filename: String { url.lastPathComponent }
    
    init(url: URL, sha: String) {
        self.url = url
        self.sha = sha
    }
}
