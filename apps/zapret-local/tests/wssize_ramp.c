// Compile on macOS with: cc -std=c11 -Wall -Werror tests/wssize_ramp.c -o /tmp/test-ramp
#include <assert.h>
#include <stddef.h>
#include "../native/wssize_ramp.h"

int main(void)
{
	struct wssize_ramp_state flow = {0};
	struct tcphdr segment = {.th_flags = TH_SYN, .th_win = htons(65535)};
	uint8_t scale = 6;
	assert(!wssize_ramp_apply(&flow, false, &segment, &scale, 0));
	assert(!wssize_ramp_apply(&flow, true, &segment, NULL, 0));
	assert(wssize_ramp_apply(&flow, true, &segment, &scale, 0));
	assert(scale == 1 && ntohs(segment.th_win) == 1);

	// A retransmitted kernel SYN still contains the original scale.
	scale = 6;
	assert(wssize_ramp_apply(&flow, true, &segment, &scale, 0));
	const uint32_t server_isn = UINT32_MAX - 1;
	segment.th_flags = TH_ACK;
	segment.th_ack = htonl(UINT32_MAX);
	for (int i = 0; i < 12; i++) {
		segment.th_win = htons(4000);
		assert(wssize_ramp_apply(&flow, true, &segment, NULL, server_isn));
		assert(ntohs(segment.th_win) == 1);
	}
	segment.th_ack = htonl(0);
	segment.th_win = htons(4000);
	assert(wssize_ramp_apply(&flow, true, &segment, NULL, server_isn));
	assert(ntohs(segment.th_win) == 65535);

	// Once negotiated, profile reselection and an old ACK must not undo scaling.
	segment.th_ack = htonl(UINT32_MAX);
	segment.th_win = htons(100);
	assert(wssize_ramp_apply(&flow, false, &segment, NULL, server_isn));
	assert(ntohs(segment.th_win) == 3200);
	segment.th_win = 0;
	assert(!wssize_ramp_apply(&flow, false, &segment, NULL, server_isn));
	assert(segment.th_win == 0);
	struct wssize_ramp_state unobserved = {0};
	assert(!wssize_ramp_apply(&unobserved, true, &segment, NULL, server_isn));
	return 0;
}
