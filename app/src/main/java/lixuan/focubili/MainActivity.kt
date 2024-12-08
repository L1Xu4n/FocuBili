package lixuan.focubili

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.PlaylistAdd
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import lixuan.focubili.ui.theme.FocuBiliTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            FocuBiliTheme {
                Scaffold(
                    modifier = Modifier.fillMaxSize(),
                ) { innerPadding ->
                    HomeScreen(modifier = Modifier.padding(innerPadding))
                }
            }
        }
    }
}


@Composable
fun HomeScreen(modifier: Modifier = Modifier) {
    var searchText by remember { mutableStateOf("") }

    Column(
        verticalArrangement = Arrangement.Center,
        modifier = modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        // 顶部应用栏
        TopAppBar(
            searchText = searchText,
            onSearchTextChange = { searchText = it }
        )

        // 主要内容区域
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(16.dp)
        ) {
            FeaturesSection()
        }
    }
}

@Composable
fun TopAppBar(
    searchText: String,
    onSearchTextChange: (String) -> Unit
) {
    Surface(
        modifier = Modifier.fillMaxWidth(),
        tonalElevation = 4.dp,
        color = MaterialTheme.colorScheme.surface
    ) {
        Column(
            modifier = Modifier.padding(16.dp)
        ) {
            // 顶部栏
            Row(
                modifier = Modifier
                    .fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "FocuBili",
                    style = MaterialTheme.typography.headlineMedium,
                    fontWeight = FontWeight.Bold
                )
                IconButton(onClick = { /*TODO*/ }) {
                    Icon(Icons.Filled.Settings, "设置")
                }
            }

            Spacer(modifier = Modifier.height(16.dp))

            // 搜索栏
            TextField(
                value = searchText,
                onValueChange = onSearchTextChange,
                modifier = Modifier
                    .fillMaxWidth()
                    .clip(RoundedCornerShape(24.dp)),
                placeholder = { Text("搜索") },
                leadingIcon = { Icon(Icons.Filled.Search, "搜索") },
                colors = TextFieldDefaults.colors(
                    unfocusedContainerColor = MaterialTheme.colorScheme.surfaceVariant,
                    focusedContainerColor = MaterialTheme.colorScheme.surfaceVariant
                ),
                singleLine = true
            )
        }
    }
}

@Composable
fun FeaturesSection() {
    val features = listOf(
        Triple(Icons.Filled.History, "历史记录", MaterialTheme.colorScheme.primary),
        Triple(Icons.Filled.Favorite, "收藏", MaterialTheme.colorScheme.secondary),
        Triple(Icons.AutoMirrored.Filled.PlaylistAdd, "稍后观看", MaterialTheme.colorScheme.tertiary),
        Triple(Icons.Filled.Download, "下载", MaterialTheme.colorScheme.error)
    )

    LazyVerticalGrid(
        columns = GridCells.Fixed(2),
        horizontalArrangement = Arrangement.spacedBy(16.dp),
        verticalArrangement = Arrangement.spacedBy(16.dp),
        modifier = Modifier.fillMaxWidth()
    ) {
        items(features) { (icon, text, color) ->
            FeatureCard(
                icon = icon,
                text = text,
                backgroundColor = color,
                onClick = { /*TODO*/ }
            )
        }
    }
}

@Composable
fun FeatureCard(
    icon: ImageVector,
    text: String,
    backgroundColor: Color,
    onClick: () -> Unit
) {
    Card(
        modifier = Modifier
            .fillMaxWidth()
            .aspectRatio(1.5f)
            .clickable(onClick = onClick),
        colors = CardDefaults.cardColors(containerColor = backgroundColor.copy(alpha = 0.9f))
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            Icon(
                imageVector = icon,
                contentDescription = text,
                modifier = Modifier.size(36.dp),
                tint = Color.White
            )
            Spacer(modifier = Modifier.height(12.dp))
            Text(
                text = text,
                color = Color.White,
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
                textAlign = TextAlign.Center
            )
        }
    }
}

// 首先定义一个数据类来存储每个象限的内容和颜色
data class QuadrantData(
    val title: String,
    val description: String,
    val backgroundColor: Color
)

// 声明所有象限的内容
private val quadrantContents = listOf(
    QuadrantData(
        title = "Text composable",
        description = "Displays text and follows the recommended Material Design guidelines.",
        backgroundColor = Color(0xFFEADDFF)
    ),
    QuadrantData(
        title = "Image composable",
        description = "Creates a composable that lays out and draws a given Painter class object.",
        backgroundColor = Color(0xFFD0BCFF)
    ),
    QuadrantData(
        title = "Row composable",
        description = "A layout composable that places its children in a horizontal sequence.",
        backgroundColor = Color(0xFFB69DF8)
    ),
    QuadrantData(
        title = "Column composable",
        description = "A layout composable that places its children in a vertical sequence.",
        backgroundColor = Color(0xFFF6EDFF)
    )
)

@Composable
fun LittleText(modifier: Modifier = Modifier, data: QuadrantData) {
    Column(
        modifier = modifier
            .fillMaxSize()
            .padding(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,) {
        Text(
            text = data.title,
            fontWeight = FontWeight.Bold,
            modifier = modifier
                .padding(bottom = 16.dp),
            textAlign = TextAlign.Justify
        )
        Text(
            text = data.description
        )
    }
}

@Composable
fun Quadrant(modifier: Modifier = Modifier, data: QuadrantData) {
    Card(
        modifier = modifier
            .fillMaxWidth()
            .fillMaxHeight(), // 设置为填充父布局
        colors = CardDefaults.cardColors(containerColor = data.backgroundColor),
        shape = RoundedCornerShape(0.dp), // 设置为直角
    ) {
        LittleText(data = data)
    }
}

@Composable
private fun ComposeQuadrant(modifier: Modifier = Modifier) {
    Column(
        modifier = modifier
            .fillMaxSize(),
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .fillMaxHeight(0.5f),
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Quadrant(
                modifier = Modifier.weight(1f),
                data = quadrantContents[0]  // 使用第一象限数据
            )
            Quadrant(
                modifier = Modifier.weight(1f),
                data = quadrantContents[1]  // 使用第二象限数据
            )
        }
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .fillMaxHeight(),
            horizontalArrangement = Arrangement.SpaceBetween
        ) {
            Quadrant(
                modifier = Modifier.weight(1f),
                data = quadrantContents[2]  // 使用第三象限数据
            )
            Quadrant(
                modifier = Modifier.weight(1f),
                data = quadrantContents[3]  // 使用第四象限数据
            )
        }
    }
}

@Preview(showBackground = true)
@Composable
fun QuadrantPreview() {
    FocuBiliTheme {
        Quadrant(data = quadrantContents[0])  // 预览第一象限
    }
}
@Preview(showBackground = true)
@Composable
fun HomeScreenPreview() {
    FocuBiliTheme {
        HomeScreen()
    }
}

@Preview(showBackground = true)
@Composable
fun ComposeQuadrantPreview() {
    FocuBiliTheme {
        ComposeQuadrant(Modifier.fillMaxSize())
    }
}