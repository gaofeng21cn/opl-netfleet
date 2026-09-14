

return function(context) {
// Bind the service functions before assigning closures that may reference them.
let public_candidates;



public_candidates = function(candidates) {
	const result = [];
	for (let i = 0; i < length(candidates) && i < 256; i++) {
		const candidate = candidates[i];
		push(result, {
			candidate_id: candidate.candidate_id,
			provider_id: candidate.provider_id,
			region_id: candidate.region_id,
			group: candidate.group,
			available: candidate.available,
			latency: candidate.latency,
			quota: candidate.quota?.state == "available" ?
				{ state: "available", remaining_bytes: candidate.quota.remaining_bytes ?? null } :
				{ state: candidate.quota?.state ?? "unknown" }
		});
	}
	return result;
};

return { public_candidates };
};
