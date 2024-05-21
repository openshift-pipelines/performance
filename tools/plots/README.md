# Plot-it

Manage and visualize plots in declarative manner.

1. Create plot.yaml using plot-it definition.
2. Run plot-it script.

## Usage

```
# Install requirements
pip install pandas==2.2.1 matplotlib==3.8.4 pydantic==2.6.3

# Update the fields in plot.yaml based on test report: events/input.path/output.dir

# Plot and generate charts
python plot-it.yaml -v
```
