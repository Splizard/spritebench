import pandas as pd
import seaborn as sns
import matplotlib.pyplot as plt
import os
import glob

def prettify_label(label):
    # Remove the _20000 part
    label = label.replace("_20000", "")
    
    parts = label.split("_")
    name_map = {
        "cs": "C#",
        "gds": "GDScript",
        "graphicsgd": "GraphicsGD",
        "rustbalanced": "Rust (Balanced)",
        "rustdisengaged": "Rust (Disengaged)"
    }
    
    name = name_map.get(parts[0], parts[0].capitalize())
    
    if "html5" in parts:
        return f"{name} (HTML5)"
    if "forwardplus" in parts:
        return f"{name} (Forward+)"
    return name

def main():
    # Use absolute path for safety
    dir_path = os.path.dirname(os.path.realpath(__file__))
    csv_files = glob.glob(os.path.join(dir_path, "*.csv"))
    data = []

    for file_path in csv_files:
        file_name = os.path.basename(file_path)
        
        # Skip empty files
        if os.path.getsize(file_path) == 0:
            print(f"Skipping empty file: {file_name}")
            continue

        label = file_name.replace(".csv", "")
        pretty_label = prettify_label(label)
        
        try:
            # The CSVs have no header and one column of frame times
            df = pd.read_csv(file_path, header=None)
            
            # Filter out zeros/negatives to avoid division by zero
            df = df[df[0] > 0]
            
            if not df.empty:
                fps_values = 1.0 / df[0]
                for fps in fps_values:
                    data.append({"Implementation": pretty_label, "FPS": fps})
            else:
                print(f"Warning: No valid frame times in {file_name}")
        except Exception as e:
            print(f"Error reading {file_name}: {e}")

    if not data:
        print("No valid data found in CSV files.")
        return

    plot_df = pd.DataFrame(data)
    
    # Calculate sort order based on mean FPS
    sort_order = plot_df.groupby("Implementation")["FPS"].mean().sort_values(ascending=False).index
    
    # Set the style
    sns.set_theme(style="whitegrid")
    plt.figure(figsize=(10, 6))
    
    # Create the bar plot
    ax = sns.barplot(
        x="FPS", 
        y="Implementation", 
        data=plot_df, 
        order=sort_order,
        hue="Implementation",
        palette="viridis",
        legend=False,
        errorbar="sd",
        capsize=0.1
    )
    
    # Add labels to bars (showing the mean)
    ax.bar_label(ax.containers[0], padding=5, fmt='%.1f')
    
    plt.title("SpriteBench Performance Comparison (20,000 Sprites)", fontsize=16, pad=20)
    plt.xlabel("Average FPS (Higher is Better, Error Bars = SD)", fontsize=12)
    plt.ylabel("Implementation", fontsize=12)
    
    # Adjust layout and save
    plt.tight_layout()
    output_path = os.path.join(dir_path, "benchmark_results.svg")
    plt.savefig(output_path)
    print(f"Plot saved to {output_path}")
    
    # Show the plot if possible (might not work in headless environment)
    try:
        plt.show()
    except Exception:
        pass

if __name__ == "__main__":
    main()
