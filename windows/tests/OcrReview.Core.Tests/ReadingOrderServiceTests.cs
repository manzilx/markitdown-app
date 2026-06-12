using OcrReview.Core.Services;
using Xunit;

namespace OcrReview.Core.Tests;

public class ReadingOrderServiceTests
{
    [Fact]
    public void Same_row_fragments_read_left_to_right()
    {
        // Engine returned value before label; baselines jittered by a few pixels.
        var boxes = new List<(double X, double Y, double W, double H)>
        {
            (600, 102, 200, 20),   // "ACME Corp" (value)
            (80, 100, 150, 20),    // "Company" (label)
        };
        Assert.Equal(new List<int> { 1, 0 }, ReadingOrderService.Order(boxes));
    }

    [Fact]
    public void Rows_read_top_to_bottom_despite_scrambled_input()
    {
        var boxes = new List<(double X, double Y, double W, double H)>
        {
            (80, 300, 150, 20),    // row 3 label
            (80, 100, 150, 20),    // row 1 label
            (600, 198, 200, 20),   // row 2 value (jittered up)
            (600, 103, 200, 20),   // row 1 value (jittered down)
            (80, 200, 150, 20),    // row 2 label
        };
        Assert.Equal(new List<int> { 1, 3, 4, 2, 0 }, ReadingOrderService.Order(boxes));
    }

    [Fact]
    public void Plain_y_sort_jitter_does_not_swap_cells()
    {
        // The label sits 4px BELOW the value's top — a plain Y sort would emit the
        // value first; row grouping must keep label-then-value.
        var boxes = new List<(double X, double Y, double W, double H)>
        {
            (80, 104, 150, 20),    // label, lower baseline
            (600, 100, 200, 20),   // value, higher baseline
        };
        Assert.Equal(new List<int> { 0, 1 }, ReadingOrderService.Order(boxes));
    }

    [Fact]
    public void Distinct_lines_with_small_overlap_stay_separate_rows()
    {
        // 20%-height overlap (tight leading) must NOT merge two paragraph lines.
        var boxes = new List<(double X, double Y, double W, double H)>
        {
            (80, 116, 500, 20),    // second line, overlaps first by 4px
            (80, 100, 500, 20),    // first line
        };
        Assert.Equal(new List<int> { 1, 0 }, ReadingOrderService.Order(boxes));
    }

    [Fact]
    public void Empty_input_returns_empty()
    {
        Assert.Empty(ReadingOrderService.Order(new List<(double, double, double, double)>()));
    }
}
