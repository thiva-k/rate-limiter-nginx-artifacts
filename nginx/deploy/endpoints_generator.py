import os

# Define the deploy folder path
script_dir = os.path.dirname(os.path.abspath(__file__))
deploy_folder = os.path.abspath(os.path.join(script_dir, "./"))

# Construct versions dynamically
algorithms = {}
for root, _, files in os.walk(deploy_folder):
    algorithm_name = os.path.basename(root).replace("_", " ").title()  # Format algorithm name
    if algorithm_name not in algorithms:
        algorithms[algorithm_name] = []
    
    for file in files:
        if file.endswith(".lua"):
            relative_path = os.path.relpath(root, deploy_folder)
            version_name = os.path.join(relative_path, file).replace("\\", "/").replace(".lua", "")
            algorithms[algorithm_name].append(f"/{version_name}")

services = [
    "tools.descartes.teastore.auth/rest",
    "tools.descartes.teastore.recommender/rest",
    "tools.descartes.teastore.persistence/rest",
    "tools.descartes.teastore.image/rest"
]

nginx_template = """
        location {key}/{service} {{
            rewrite ^{key}(/.*)$ $1 break;
            access_by_lua_file lua_scripts{key}.lua;
            proxy_pass http://{service_name};
            proxy_http_version 1.1;
            proxy_set_header Connection "";
        }}
"""

output_filename = os.path.join(deploy_folder, "locations.conf")

# Ensure the file exists before writing
if not os.path.exists(output_filename):
    open(output_filename, "w").close()

with open(output_filename, "w") as conf_file:
    for algorithm, versions in algorithms.items():
        conf_file.write(f"\n# {algorithm} Endpoints\n")  # Add comment as heading for each algorithm
        for version in versions:
            conf_file.write(f"\n# # {version.split('/')[-1]}\n")  # Add comment with version name
            for service in services:
                service_name = service.split(".")[-1].split("/")[0]  # Correct extraction of service name
                conf_file.write(nginx_template.format(key=version, service=service, service_name=service_name))

print(f"Nginx configuration written to {output_filename}")